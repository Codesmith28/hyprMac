import CoreGraphics

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
    public static func shouldFloat(firstSeenSize size: CGSize, config: Config, override: FloatMode? = nil) -> Bool {
        if let override { return override == .floating }
        return isSmall(size, minWidth: config.floatMinWidth, minHeight: config.floatMinHeight)
    }

    public static func isSmall(_ size: CGSize, minWidth: Double, minHeight: Double) -> Bool {
        (minWidth > 0 && Double(size.width) < minWidth) || (minHeight > 0 && Double(size.height) < minHeight)
    }
}
