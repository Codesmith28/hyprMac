import CoreGraphics
import HyprPlatform

/// How a window is treated regardless of its size (an explicit override, e.g. a future "toggle float").
public enum FloatMode: Equatable {
    case tiled
    case floating
}

/// Krohnkite-style "small windows float". Pure: decides from the size a window had when
/// hyprMac FIRST saw it, the thresholds and an optional override.
public enum FloatPolicy {
    /// True when the window should float.
    /// - A zero threshold disables that axis; a size exactly at the threshold tiles.
    /// - An override always wins over the size rule.
    public static func shouldFloat(firstSeenSize size: CGSize, config: Config, override: FloatMode? = nil,
                                   title: String? = nil) -> Bool {
        if let override { return override == .floating }
        if matchesFloatTitle(title, config: config) { return true }
        return isSmall(size, minWidth: config.floatMinWidth, minHeight: config.floatMinHeight)
    }

    /// `rules.float_title`: true when `title` is non-empty and matches a pattern.
    public static func matchesFloatTitle(_ title: String?, config: Config) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return config.rules.floatTitleMatcher.matches(title)
    }

    public static func isSmall(_ size: CGSize, minWidth: Double, minHeight: Double) -> Bool {
        (minWidth > 0 && Double(size.width) < minWidth) || (minHeight > 0 && Double(size.height) < minHeight)
    }
}
