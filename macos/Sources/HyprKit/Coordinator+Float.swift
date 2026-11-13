import CoreGraphics
import Foundation
import HyprPlatform

extension Coordinator {
    /// Decides (once per window id) whether the window floats because it was small when first seen.
    ///
    /// The decision uses the size from the first reconcile in which the window is tiled-eligible with
    /// a usable frame, i.e. before hyprMac ever resized it, and is sticky: later resizes don't change
    /// it. `floatOverride[id]` wins over the size rule. A config reload with new thresholds applies
    /// only to windows first seen afterwards. Runs on the coordinator queue.
    func floatsAsSmall(id: UInt64, frame: CGRect) -> Bool {
        if let override = floatOverride[id] { return override } // true = floating (⌥⇧F)
        if let decided = floatDecided[id] { return decided }
        let f = Self.sanitized(frame)
        guard f.width > 0, f.height > 0 else { return false } // no real size yet; decide later
        let small = FloatPolicy.shouldFloat(firstSeenSize: f.size, config: currentConfig)
        floatDecided[id] = small
        if small {
            EventLog.shared.emit("floated", ["window": Int(id), "reason": "small"])
        }
        return small
    }
}

extension Coordinator {
    /// `rules.float_title`: decided once per window from the first non-empty title it shows (titles of
    /// tabbed apps change constantly, so later titles never flip the decision). The ⌥⇧F override wins.
    func floatsByTitle(id: UInt64, title: String?) -> Bool {
        if let decided = titleFloatDecided[id] { return decided }
        guard !currentConfig.rules.floatTitle.isEmpty, let title, !title.isEmpty else { return false }
        let hit = FloatPolicy.matchesFloatTitle(title, config: currentConfig)
        titleFloatDecided[id] = hit
        if hit { EventLog.shared.emit("floated", ["window": Int(id), "reason": "title"]) }
        return hit
    }

    /// `config.displays` / `config.smart_gaps` → engine. Called before every reconcile pass, so a
    /// reload, a renamed or unplugged display and a new display all take effect on the next plan.
    func syncGaps(displays: [DisplayInfo]) {
        engine.setSmartGaps(currentConfig.smartGaps)
        for d in displays {
            let o = currentConfig.displays[d.name]
            engine.setDisplayGaps(display: d.id, inner: o?.inner, outer: o?.outer)
        }
    }

    /// Logs `config.displays` names that match no connected display (they are ignored).
    func logUnknownDisplays(_ displays: [DisplayInfo]) {
        let known = Set(displays.map(\.name))
        let unknown = currentConfig.displays.keys.filter { !known.contains($0) }.sorted()
        guard !unknown.isEmpty else { return }
        logger.notice("config.displays: no connected display named \(unknown.joined(separator: ", "), privacy: .public); ignored. Connected: \(known.sorted().joined(separator: ", "), privacy: .public)")
        EventLog.shared.emit("displays_unknown", ["names": unknown, "connected": known.sorted()])
    }
}
