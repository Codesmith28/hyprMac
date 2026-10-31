import CoreGraphics
import Foundation

extension Coordinator {
    /// Decides (once per window id) whether the window floats because it was small when first seen.
    ///
    /// The decision uses the size from the first reconcile in which the window is tiled-eligible with
    /// a usable frame, i.e. before hyprMac ever resized it, and is sticky: later resizes don't change
    /// it. `floatOverride[id]` wins over the size rule. A config reload with new thresholds applies
    /// only to windows first seen afterwards. Runs on the coordinator queue.
    func floatsAsSmall(id: UInt64, frame: CGRect) -> Bool {
        if let override = floatOverride[id] { return override == .floating }
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
