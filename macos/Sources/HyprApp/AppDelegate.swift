import AppKit
import ApplicationServices
import HyprKit
import os

let log = Logger(subsystem: "dev.codesmith28.hyprmac", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, TilingControllerDelegate {
    private let options: AppOptions
    private var statusItem: NSStatusItem!
    private var controller: TilingController?
    private let notifier = Notifier()
    private var signalSources: [DispatchSourceSignal] = []
    private var permissionTimer: Timer?
    private var pauseItem: NSMenuItem!

    init(options: AppOptions) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        EventLog.shared.emit("started", ["version": Engine.version])
        buildMenu()
        installSignalHandlers()
        notifier.requestAuthorization()
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
            self?.startTiling()
        }
    }

    private func startTiling() {
        let configPath = options.configPath.map { URL(fileURLWithPath: $0) } ?? ConfigStore.defaultPath
        let c = Coordinator.live(configPath: configPath)
        c.delegate = self
        controller = c
        c.start()
        refreshMenu()
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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Configuration…", action: #selector(openConfig), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Reload Configuration", action: #selector(reloadConfig), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Keyboard Shortcuts…", action: #selector(showShortcuts), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit hyprMac", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func refreshMenu() {
        pauseItem.title = (controller?.isPaused ?? false) ? "Resume Tiling" : "Pause Tiling"
        statusItem.button?.appearsDisabled = controller?.isPaused ?? true
    }

    @objc private func togglePause() {
        guard let c = controller else { return }
        c.setPaused(!c.isPaused, reason: "user")
        refreshMenu()
    }
    @objc private func retile() { controller?.retileAll() }
    @objc private func reloadConfig() { controller?.reloadConfig() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showShortcuts() { Onboarding.showShortcuts() }

    @objc private func openConfig() {
        let path = options.configPath.map { URL(fileURLWithPath: $0) } ?? ConfigStore.defaultPath
        let example = Bundle.main.url(forResource: "init.lua", withExtension: "example")
        do {
            let url = try ConfigStore(path: path).ensureExists(example: example)
            NSWorkspace.shared.open(url)
        } catch {
            notifier.post(title: "Couldn't create configuration", body: error.localizedDescription)
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
            notifier.post(title: "Desktop \(n) doesn't exist",
                          body: count == 1 ? "You have 1 desktop. Add more in Mission Control."
                                           : "You have \(count) desktops. Add more in Mission Control.",
                          id: "missing-space")
        case let .throwFailed(n, reason):
            notifier.post(title: "Couldn't move window to Desktop \(n)", body: reason, id: "throw")
        case let .configError(msg):
            notifier.post(title: "Configuration error — kept previous settings", body: msg, id: "config")
        case .configLoaded:
            break
        case .stageManagerEnabled:
            notifier.post(title: "Tiling paused: Stage Manager is on",
                          body: "Turn off Stage Manager in Control Center to resume tiling.", id: "stage-manager")
        case let .conflictingApp(name):
            notifier.post(title: "\(name) is running",
                          body: "\(name) may move windows too. Quit it if windows jump around.", id: "conflict-\(name)")
        case .permissionLost:
            notifier.post(title: "Accessibility permission was removed",
                          body: "hyprMac paused. Re-enable it in System Settings ▸ Privacy & Security ▸ Accessibility.",
                          id: "permission")
            controller.stop()
            waitForPermission()
        }
        refreshMenu()
    }
}
