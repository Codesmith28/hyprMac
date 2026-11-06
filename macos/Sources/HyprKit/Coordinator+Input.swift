import CoreGraphics
import Foundation
import HyprPlatform

/// Configurable shortcuts (`config.keys`) and app rules (`config.rules`).
extension Coordinator {

    /// (Re-)registers the throw / toggle-float hotkeys and the switch-key tap for `keys`, applies the
    /// switch modifiers to the throw's native-shortcut fallback, and warns when `keys.switch` doesn't
    /// match the user's native shortcut. Called from `applyConfig` (start and every successful reload)
    /// on `queue`; the registration itself runs on the main thread.
    func bindInput(_ keys: KeyBindings) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard running else { return }
        mover.fallbackSwitchFlags = keys.switchModifiers.cgFlags
        deps.onMain { [self] in
            deps.hotkeys.onToggleFloat = { [weak self] in self?.toggleFocusedFloat() }
            deps.hotkeys.onCenterWindow = { [weak self] in self?.centerFocusedWindow() }
            deps.hotkeys.onFocusDirection = { [weak self] dir in self?.focus(direction: dir) }
            deps.hotkeys.onMoveDirection = { [weak self] dir in self?.move(direction: dir) }
            let failed = deps.hotkeys.start(bindings: keys) { [weak self] n in self?.throwFocusedWindow(toSpace: n) }
            var unavailable: [String] = []
            if !failed.isEmpty {
                logger.error("\(keys.throwModifiers.symbols) hotkeys unavailable for digits \(failed)")
                unavailable.append("\(keys.throwModifiers.symbols)\(failed.map(String.init).joined(separator: "/"))")
            }
            if deps.hotkeys.toggleFloatFailed {
                logger.error("\(keys.toggleFloat.display) hotkey unavailable")
                unavailable.append(keys.toggleFloat.display)
            }
            if !deps.spaceKeys.start(modifiers: keys.switchModifiers.cgFlags,
                                     onSwitch: { [weak self] n in self?.spaceKeyPressed(n) }) {
                logger.error("space key observer unavailable; missing-space notices disabled")
            }
            if !unavailable.isEmpty { notify(.hotkeysUnavailable(unavailable.joined(separator: ", "))) }
        }
        checkSwitchShortcut(keys.switchModifiers)
    }

    /// The throw posts the native shortcut's real modifiers, but the missing-Desktop notice listens
    /// for `keys.switch`: tell the user when no enabled "Switch to Desktop N" shortcut uses them.
    private func checkSwitchShortcut(_ configured: KeyModifiers) {
        guard let shortcuts = deps.nativeShortcuts else { return }
        let native = shortcuts.enabledModifiers().values
        guard !native.contains(configured.cgFlags) else { return }
        let names = Set(native.map { KeyModifiers(cgFlags: $0).symbols }).sorted()
        EventLog.shared.emit("switch_shortcut_mismatch", ["configured": configured.symbols, "native": names])
        notify(.switchShortcutMismatch(configured: configured.symbols, native: names))
    }

    /// `rules.ignore` hides apps from discovery (never tiled, never moved). `rules.float` is applied
    /// in `reconcileNow` through `ruleFloatPids()`, as an automatic decision the ⌥⇧F override beats
    /// (unlike the built-in float list, which ⌥⇧F never overrides).
    func applyRules(_ rules: AppRules) {
        discovery.configuration.ignoreBundleIDs = Set(rules.ignore)
    }

    /// Running apps whose bundle id is in `rules.float`.
    func ruleFloatPids() -> Set<pid_t> {
        let float = Set(currentConfig.rules.float)
        guard !float.isEmpty else { return [] }
        return Set(deps.apps.runningApplications().compactMap { app in
            app.bundleID.flatMap { float.contains($0) ? app.pid : nil }
        })
    }

    /// True when `pid` belongs to an app in `rules.ignore` (hotkeys never act on it).
    func isIgnored(pid: pid_t) -> Bool {
        let ignore = discovery.configuration.ignoreBundleIDs
        guard !ignore.isEmpty, let app = deps.apps.runningApplications().first(where: { $0.pid == pid }),
              let bundle = app.bundleID else { return false }
        return ignore.contains(bundle)
    }
}
