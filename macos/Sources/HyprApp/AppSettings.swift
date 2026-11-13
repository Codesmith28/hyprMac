import HyprKit

/// User choices that outlive a launch, kept in the existing `AppStateStore` (state.json) rather than
/// UserDefaults, so the install rollback never has to know about them. Each setting is one entry under
/// a reserved key (no real bundle id looks like that); `.tiled` / `.floating` encode true / false.
struct AppSettings {
    static let keyPrefix = "dev.codesmith28.hyprmac.setting."
    static let pausedKey = keyPrefix + "paused"
    static let osdPopupKey = keyPrefix + "osd_popup"

    let store: AppStateStore

    /// Tiling was paused by the user when the app last ran.
    var paused: Bool {
        get { bool(Self.pausedKey) ?? false }
        nonmutating set { set(Self.pausedKey, newValue) }
    }

    /// The menu's OSD choice; nil = follow `osd_popup` from the config.
    var osdPopupOverride: Bool? {
        get { bool(Self.osdPopupKey) }
        nonmutating set { set(Self.osdPopupKey, newValue) }
    }

    func osdEnabled(configDefault: Bool) -> Bool { osdPopupOverride ?? configDefault }

    private func bool(_ key: String) -> Bool? {
        store.savedState(for: key).map { $0.state == .tiled }
    }

    private func set(_ key: String, _ value: Bool?) {
        if let value { store.save(bundleID: key, state: value ? .tiled : .floating) } else { store.remove(bundleID: key) }
    }
}
