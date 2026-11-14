import Foundation

/// "Displays have separate Spaces" (System Settings ▸ Desktop & Dock ▸ Mission Control).
/// With it off macOS shows one shared set of Spaces on every display, which breaks per-display
/// tiling and numbering. With a single display it makes no difference.
public enum SeparateSpaces {
    /// True when the setting is off while more than one display is connected.
    public static func shouldWarn(displaysHaveSeparateSpaces: Bool, displayCount: Int) -> Bool {
        !displaysHaveSeparateSpaces && displayCount > 1
    }
}
