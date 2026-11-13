import AppKit
import ApplicationServices
import HyprKit
import HyprPlatform
import os

let log = Logger(subsystem: "dev.codesmith28.hyprmac", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, TilingControllerDelegate {
    private let options: AppOptions
    private var statusItem: NSStatusItem!
    private var controller: TilingController?
    private let notifier = Notifier()
    private let osdNotifier = OSDNotifier()
    private var signalSources: [DispatchSourceSignal] = []
    private var permissionTimer: Timer?
    private var pauseItem: NSMenuItem!
    private var services: BackgroundServices?
    private var osdItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var statusMenu: NSMenu!
    private var grantInputItem: NSMenuItem!
    /// Shared with the coordinator so both write the same state.json.
    private let stateStore = AppStateStore()
    private lazy var settings = AppSettings(store: stateStore)
    private let login = LoginItem()
    /// Set when tiling starts after a permission wait: shows a one-time "Tiling started" OSD.
    private var announceStart = false

    init(options: AppOptions) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        EventLog.shared.emit("started", ["version": Engine.version])
        buildMenu()
        installSignalHandlers()
        notifier.requestAuthorization()
        notifier.onAction = { [weak self] in self?.perform($0) }
        if AXIsProcessTrusted() {
            startTiling()
        } else {
            EventLog.shared.emit("paused", ["reason": "accessibility"])
            // Under the E2E harness (--event-log) a modal alert would block the
            // run; the event above is the report.
            if options.eventLogPath == nil { Onboarding.showAccessibilityPrompt() }
            waitForPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.stop()
        controller?.stop()
        EventLog.shared.emit("stopped")
    }

    // MARK: - lifecycle

    private func waitForPermission() {
        statusItem.button?.appearsDisabled = true
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard AXIsProcessTrusted() else { return }
            t.invalidate()
            self?.statusItem.button?.appearsDisabled = false
            self?.announceStart = true
            self?.startTiling()
        }
    }

    private func startTiling() {
        let configPath = options.configPath.map { URL(fileURLWithPath: $0) } ?? ConfigStore.defaultPath
        let c = Coordinator.live(configPath: configPath, appStateStore: stateStore)
        c.delegate = self
        controller = c
        c.start()
        if settings.paused { c.setPaused(true, reason: "user") }
        services?.stop()
        services = BackgroundServices(controller: c, configPath: configPath,
                                      version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? Engine.version)
        services?.start()
        refreshMenu()
        if announceStart {
            announceStart = false
            // The config loads on the coordinator queue; give it a moment so `osd_popup = false` is honoured.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.osdEnabled else { return }
                self.osdNotifier.showNotice("Tiling started", symbol: "square.split.2x2")
            }
        }
    }

    /// SIGHUP reloads the config; SIGTERM/SIGINT quit cleanly (tiling stopped,
    /// observers and hotkeys released) instead of dying mid-write.
    private func installSignalHandlers() {
        func on(_ sig: Int32, _ handler: @escaping () -> Void) {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler(handler: handler)
            src.resume()
            signalSources.append(src)
        }
        on(SIGHUP) { [weak self] in self?.controller?.reloadConfig() }
        on(SIGTERM) { NSApp.terminate(nil) }
        on(SIGINT) { NSApp.terminate(nil) }
    }

    // MARK: - menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.split.2x2", accessibilityDescription: "hyprMac")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let title = NSMenuItem(title: "hyprMac \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        pauseItem = NSMenuItem(title: "Pause Tiling", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(pauseItem)
        menu.addItem(NSMenuItem(title: "Retile All Windows", action: #selector(retile), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Flip Split of Focused Window", action: #selector(flipSplit), keyEquivalent: ""))
        menu.addItem(.separator())
        osdItem = NSMenuItem(title: "OSD Popups", action: #selector(toggleOSD), keyEquivalent: "")
        menu.addItem(osdItem)
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(loginItem)
        menu.addItem(.separator())
        // No key equivalents: an accessory app's menu can never receive them.
        menu.addItem(NSMenuItem(title: "Open Configuration…", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal Configuration in Finder", action: #selector(revealConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reload Configuration", action: #selector(reloadConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Keyboard Shortcuts…", action: #selector(showShortcuts), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Log Command", action: #selector(copyLogCommand), keyEquivalent: ""))
        menu.addItem(.separator())
        let statusParent = NSMenuItem(title: "Status", action: nil, keyEquivalent: "")
        statusMenu = NSMenu(title: "Status")
        statusParent.submenu = statusMenu
        menu.addItem(statusParent)
        grantInputItem = NSMenuItem(title: "Grant Input Monitoring…", action: #selector(grantInputMonitoring), keyEquivalent: "")
        menu.addItem(grantInputItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit hyprMac", action: #selector(quit), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Status rows, login state and the Input Monitoring item are re-read every time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        pauseItem.title = (controller?.isPaused ?? false) ? "Resume Tiling" : "Pause Tiling"
        let paused = controller?.isPaused ?? true
        statusItem.button?.appearsDisabled = paused
        updateStatusIcon(paused: paused)
        osdItem.state = osdEnabled ? .on : .off
        loginItem.isEnabled = login.isAvailable
        loginItem.state = login.isAvailable && login.isEnabled ? .on : .off
        refreshStatusMenu()
    }

    /// A different symbol while paused, so the state is visible even when the icon isn't dimmed.
    private func updateStatusIcon(paused: Bool) {
        let name = paused ? "pause.rectangle" : "square.split.2x2"
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "hyprMac")
            ?? NSImage(systemSymbolName: "square.split.2x2", accessibilityDescription: "hyprMac")
        button.image?.isTemplate = true
    }

    private var keyBindings: KeyBindings { controller?.keyBindings ?? .defaults }

    /// The menu's OSD choice, else the config's `osd_popup` (true before tiling has started).
    private var osdEnabled: Bool { settings.osdEnabled(configDefault: controller?.osdPopup ?? true) }

    private func refreshStatusMenu() {
        let snapshot = SystemSnapshot.current(keys: keyBindings)
        statusMenu.removeAllItems()
        for row in Diagnostics.rows(snapshot) {
            let item = NSMenuItem(title: row.text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            statusMenu.addItem(item)
        }
        grantInputItem.isHidden = snapshot.inputMonitoring
    }

    @objc private func togglePause() {
        guard let c = controller else { return }
        let paused = !c.isPaused
        c.setPaused(paused, reason: "user")
        settings.paused = paused
        refreshMenu()
    }
    @objc private func retile() { controller?.retileAll() }
    @objc private func flipSplit() { controller?.rotateFocusedSplit() }
    @objc private func reloadConfig() { controller?.reloadConfig() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showShortcuts() { Onboarding.showShortcuts(rows: ShortcutList.rows(for: keyBindings)) }

    @objc private func toggleOSD() {
        settings.osdPopupOverride = !osdEnabled
        refreshMenu()
    }

    @objc private func toggleLogin() {
        if !login.setEnabled(!login.isEnabled) { log.error("launch-at-login toggle failed") }
        refreshMenu()
    }

    @objc private func copyLogCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(AppDelegate.logCommand, forType: .string)
    }
    static let logCommand = "log stream --level info --predicate 'subsystem == \"dev.codesmith28.hyprmac\"'"

    @objc private func grantInputMonitoring() {
        _ = CGRequestListenEventAccess()
        perform(.inputMonitoring)
    }

    @objc private func revealConfig() {
        if let url = ensureConfig() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// What a notification click opens: a Settings pane, or the config file.
    private func perform(_ action: NotificationAction) {
        if let url = action.settingsURL { NSWorkspace.shared.open(url) }
        else if let url = ensureConfig() { NSWorkspace.shared.open(url) }
    }

    @objc private func openConfig() {
        if let url = ensureConfig() { NSWorkspace.shared.open(url) }
    }

    /// The config file, created from the bundled example if missing.
    private func ensureConfig() -> URL? {
        let path = options.configPath.map { URL(fileURLWithPath: $0) } ?? ConfigStore.defaultPath
        let example = Bundle.main.url(forResource: "init.lua", withExtension: "example")
        do {
            return try ConfigStore(path: path).ensureExists(example: example)
        } catch {
            notifier.post(title: "Couldn't create configuration", body: error.localizedDescription)
            return nil
        }
    }

    // MARK: - TilingControllerDelegate

    // The coordinator may call these synchronously from inside its own serial
    // queue (start() runs queue.sync on main and its onMain runs inline there).
    // Calling back into it (isPaused, stop()) from that stack is a re-entrant
    // dispatch_sync and traps, so always handle them on the next main-loop turn.

    func tilingStateChanged(_ controller: TilingController) {
        DispatchQueue.main.async { [weak self] in self?.refreshMenu() }
    }

    func tiling(_ controller: TilingController, didPost notice: TilingNotice) {
        DispatchQueue.main.async { [weak self] in self?.handle(notice, from: controller) }
    }

    private func handle(_ notice: TilingNotice, from controller: TilingController) {
        switch notice {
        case let .missingSpace(n, count):
            if osdEnabled { osdNotifier.showNotice("Desktop \(n) doesn't exist"); break }
            notifier.post(title: "Desktop \(n) doesn't exist",
                          body: count == 1 ? "You have 1 desktop. Add more in Mission Control."
                                           : "You have \(count) desktops. Add more in Mission Control.",
                          id: "missing-space")
        case let .throwFailed(n, reason):
            if osdEnabled {
                log.notice("throw to Desktop \(n) failed: \(reason, privacy: .public)")
                osdNotifier.showNotice("Couldn't move to Desktop \(n)")
                break
            }
            notifier.post(title: "Couldn't move window to Desktop \(n)", body: reason, id: "throw")
        case let .configError(msg):
            notifier.post(title: "Configuration error — kept previous settings", body: msg, id: "config", action: .config)
        case .configLoaded:
            break
        case .stageManagerEnabled:
            notifier.post(title: "Tiling paused: Stage Manager is on",
                          body: "Turn off Stage Manager in Control Center to resume tiling.", id: "stage-manager")
        case let .conflictingApp(name):
            notifier.post(title: "\(name) is running",
                          body: "\(name) may move windows too. Quit it if windows jump around.", id: "conflict-\(name)")
        case .separateSpacesOff:
            notifier.post(title: "Turn on “Displays have separate Spaces”",
                          body: "Several displays are connected but this is off, so tiling and Desktop numbers are unreliable. Turn it on in System Settings ▸ Desktop & Dock ▸ Mission Control, then log out and back in.",
                          id: "separate-spaces")
        case let .hotkeysUnavailable(what):
            notifier.post(title: "Some shortcuts are unavailable",
                          body: "\(what) — another app may be using them. Change them in init.lua (keys).",
                          id: "hotkeys", action: .config)
        case let .switchShortcutMismatch(configured, native):
            let body = native.isEmpty
                ? "No “Switch to Desktop N” shortcut is enabled in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control."
                : "keys.switch is \(configured), but macOS switches Desktops with \(native.joined(separator: " / ")). Make them match."
            notifier.post(title: "Desktop switch shortcut mismatch", body: body, id: "switch-shortcut",
                          action: .keyboardShortcuts)
        case .permissionLost:
            notifier.post(title: "Accessibility permission was removed",
                          body: "hyprMac paused. Re-enable it in System Settings ▸ Privacy & Security ▸ Accessibility.",
                          id: "permission", action: .accessibility)
            controller.stop()
            waitForPermission()
        case let .windowStateToggled(app, state):
            if osdEnabled {
                osdNotifier.show(app: app, state: state)
            }
        case let .windowCentered(app):
            if osdEnabled {
                osdNotifier.showCentered(app: app)
            }
        case let .spaceSwitched(toSpace):
            if osdEnabled {
                osdNotifier.showSpaceSwitch(toSpace: toSpace)
            }
        case let .windowThrown(app, fromSpace, toSpace):
            if osdEnabled {
                osdNotifier.showSpaceThrow(app: app, fromSpace: fromSpace, toSpace: toSpace)
            }
        }
        refreshMenu()
    }
}
