import ApplicationServices
import CoreGraphics
import HyprKit
import HyprPlatform

/// What the Status submenu reports. Gathering is separate from presenting so the presentation is testable.
struct SystemSnapshot: Equatable {
    var accessibility: Bool
    var inputMonitoring: Bool
    var stageManagerOff: Bool
    var switchShortcutMatches: Bool

    /// Live values. Reuses the platform's system-state and native-shortcut readers.
    static func current(keys: KeyBindings,
                        systemState: SystemStateQuery = SystemStateReader(),
                        native: NativeSwitchShortcuts = SystemNativeSwitchShortcuts()) -> SystemSnapshot {
        SystemSnapshot(accessibility: AXIsProcessTrusted(),
                       inputMonitoring: CGPreflightListenEventAccess(),
                       stageManagerOff: !systemState.isStageManagerEnabled,
                       switchShortcutMatches: native.matches(keys.switchModifiers))
    }
}

struct DiagnosticRow: Equatable {
    let title: String
    let ok: Bool
    /// "✓ Accessibility" / "✗ Accessibility".
    var text: String { (ok ? "✓ " : "✗ ") + title }
}

enum Diagnostics {
    static func rows(_ s: SystemSnapshot) -> [DiagnosticRow] {
        [
            DiagnosticRow(title: "Accessibility", ok: s.accessibility),
            DiagnosticRow(title: "Input Monitoring", ok: s.inputMonitoring),
            DiagnosticRow(title: "Stage Manager off", ok: s.stageManagerOff),
            DiagnosticRow(title: "Desktop switch shortcut matches keys.switch", ok: s.switchShortcutMatches),
        ]
    }
}
