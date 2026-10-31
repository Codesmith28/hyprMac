import AppKit

func NSScreenPrimaryHeight() -> CGFloat {
    NSScreen.screens.first?.frame.height ?? 0
}

/// Calling the (deprecated in 14) forced activation through a protocol keeps
/// the build warning-free; cooperative `activate()` does not reliably take
/// focus from the launching terminal.
private protocol LegacyActivation { func activate(ignoringOtherApps flag: Bool) }
extension NSApplication: LegacyActivation {}

/// Window whose Accessibility subrole is AXDialog, like a real alert/dialog.
final class DialogWindow: NSWindow {
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .dialog }
}

final class FixtureController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let options: FixtureOptions
    private var windows: [Int: NSWindow] = [:]          // command index -> window
    private var indexOf: [ObjectIdentifier: Int] = [:]
    private var originalSize: [Int: CGSize] = [:]
    private var tabs: [NSWindow] = []
    private var aux: [NSWindow] = []
    private var nextIndex = 0
    private var internalChange = 0                       // >0 while we move our own windows
    private var snapTimers: [Int: DispatchWorkItem] = [:]
    private var slowTimers: [Int: DispatchWorkItem] = [:]
    private var appliedFrame: [Int: CGRect] = [:]        // --slow-resize: last frame we accepted
    private var pendingFrame: [Int: CGRect] = [:]
    private var quitting = false

    init(options: FixtureOptions) { self.options = options }

    // MARK: launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        (NSApp as LegacyActivation).activate(ignoringOtherApps: true)   // once, at launch
        startStdinReader()

        if let hang = options.hang {
            DispatchQueue.main.asyncAfter(deadline: .now() + hang.after) {
                Out.emit(["event": "hang", "seconds": hang.seconds])
                Thread.sleep(forTimeInterval: hang.seconds)
                Out.emit(["event": "hang_end"])
            }
        }
        if let fs = options.fullscreenAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + fs) { [weak self] in
                self?.windows[0]?.toggleFullScreen(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + options.lateWindow) { [weak self] in
            self?.openInitialWindows(remaining: self?.options.windows ?? 0)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func openInitialWindows(remaining: Int) {
        guard remaining > 0 else { finishInitialSetup(); return }
        let idx = openWindow()
        if idx == 0 && options.tabs > 1 { addTabs(to: windows[0]!) }
        let delay = Double(options.staggerMS) / 1000
        if remaining == 1 {
            finishInitialSetup()
        } else if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.openInitialWindows(remaining: remaining - 1)
            }
        } else {
            openInitialWindows(remaining: remaining - 1)
        }
    }

    private func finishInitialSetup() {
        if options.sheet, let first = windows[0] {
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            first.beginSheet(sheet) { _ in }
            aux.append(sheet)
            emitAux(sheet, kind: "sheet")
        }
        if options.panel {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 180),
                                styleMask: [.titled, .closable, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.title = "\(options.title) panel"
            place(panel, slot: 7)
            panel.orderFront(nil)
            aux.append(panel)
            emitAux(panel, kind: "panel")
        }
        if options.dialog {
            let dialog = DialogWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
            dialog.level = .modalPanel
            dialog.isReleasedWhenClosed = false
            dialog.title = "\(options.title) dialog"
            dialog.tabbingMode = .disallowed
            place(dialog, slot: 8)
            dialog.makeKeyAndOrderFront(nil)
            aux.append(dialog)
            emitAux(dialog, kind: "dialog")
        }
        var ready: [String: Any] = ["event": "ready", "pid": Int(getpid()), "windows": windows.count]
        if let screen = windows[0]?.screen ?? NSScreen.main ?? NSScreen.screens.first {
            ready["screen"] = ["frame": topLeftArray(screen.frame), "visible": topLeftArray(screen.visibleFrame)]
        }
        Out.emit(ready)
    }

    // MARK: windows

    @discardableResult
    private func openWindow() -> Int {
        let idx = nextIndex
        nextIndex += 1
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if options.isResizable(idx) { style.insert(.resizable) }
        var size = options.windowSize
        if let min = options.minSize(for: idx) {
            size = CGSize(width: max(size.width, min.width), height: max(size.height, min.height))
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: style, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "\(options.title) \(idx)"
        w.delegate = self
        w.tabbingMode = (idx == 0 && options.tabs > 1) ? .preferred : .disallowed
        if idx == 0 && options.tabs > 1 { w.tabbingIdentifier = "hyprmac-fixture-tabs-\(getpid())" }
        if options.isResizable(idx) { w.collectionBehavior.insert(.fullScreenPrimary) }
        if let min = options.minSize(for: idx) { w.contentMinSize = min }
        w.contentView = label("\(options.title) \(idx)")
        windows[idx] = w
        indexOf[ObjectIdentifier(w)] = idx
        internalChange += 1
        place(w, slot: idx)
        internalChange -= 1
        originalSize[idx] = w.frame.size
        appliedFrame[idx] = w.frame
        w.makeKeyAndOrderFront(nil)
        Out.emit(["event": "window", "index": idx, "windowNumber": w.windowNumber,
                  "pid": Int(getpid()), "title": w.title, "frame": topLeftArray(w.frame),
                  "resizable": options.isResizable(idx)])
        return idx
    }

    private func addTabs(to first: NSWindow) {
        for t in 1..<options.tabs {
            let tab = NSWindow(contentRect: first.contentRect(forFrameRect: first.frame),
                               styleMask: first.styleMask, backing: .buffered, defer: false)
            tab.isReleasedWhenClosed = false
            tab.title = "\(options.title) 0 tab \(t)"
            tab.tabbingMode = .preferred
            tab.tabbingIdentifier = first.tabbingIdentifier
            tab.contentView = label(tab.title)
            first.addTabbedWindow(tab, ordered: .above)
            tabs.append(tab)
            Out.emit(["event": "tab", "group": 0, "tab": t, "windowNumber": tab.windowNumber,
                      "pid": Int(getpid()), "frame": topLeftArray(tab.frame)])
        }
        first.makeKeyAndOrderFront(nil)   // select the first tab again
    }

    private func label(_ text: String) -> NSView {
        let v = NSTextField(labelWithString: text)
        v.alignment = .center
        v.font = .systemFont(ofSize: 18, weight: .medium)
        return v
    }

    /// Cascade from the top-left of the usable area; slots wrap so nothing
    /// lands off-screen.
    private func place(_ w: NSWindow, slot: Int) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let step = CGFloat(slot % 10) * 36
        let top = NSPoint(x: vf.minX + 60 + step, y: vf.maxY - 60 - step)
        w.setFrameTopLeftPoint(top)
    }

    private func emitAux(_ w: NSWindow, kind: String) {
        Out.emit(["event": "aux", "kind": kind, "windowNumber": w.windowNumber,
                  "pid": Int(getpid()), "frame": topLeftArray(w.frame)])
    }

    private func index(of n: Notification) -> Int? {
        guard let w = n.object as? NSWindow else { return nil }
        return indexOf[ObjectIdentifier(w)]
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ n: Notification) { externalChange(n, resized: true) }
    func windowDidMove(_ n: Notification) { externalChange(n, resized: false) }

    private func externalChange(_ n: Notification, resized: Bool) {
        guard internalChange == 0, let idx = index(of: n), let w = windows[idx] else { return }
        if w.styleMask.contains(.fullScreen) || w.isMiniaturized { return }
        if options.slowResizeMS > 0 {
            // Revert now, apply the requested frame late (debounced).
            pendingFrame[idx] = w.frame
            if let applied = appliedFrame[idx], applied != w.frame {
                internalChange += 1
                w.setFrame(applied, display: true)
                internalChange -= 1
            }
            slowTimers[idx]?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, let w = self.windows[idx], let target = self.pendingFrame[idx] else { return }
                self.internalChange += 1
                w.setFrame(target, display: true)
                self.internalChange -= 1
                self.appliedFrame[idx] = target
                Out.emit(["event": "slow_resize_applied", "index": idx, "frame": topLeftArray(target)])
                if self.options.snapBack { self.scheduleSnapBack(idx) }
            }
            slowTimers[idx] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(options.slowResizeMS) / 1000, execute: item)
            return
        }
        appliedFrame[idx] = w.frame
        if options.snapBack && resized { scheduleSnapBack(idx) }
    }

    private func scheduleSnapBack(_ idx: Int) {
        snapTimers[idx]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let w = self.windows[idx], let size = self.originalSize[idx] else { return }
            guard w.frame.size != size, !w.styleMask.contains(.fullScreen) else { return }
            let top = NSPoint(x: w.frame.minX, y: w.frame.maxY)
            let f = NSRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height)
            self.internalChange += 1
            w.setFrame(f, display: true)
            self.internalChange -= 1
            self.appliedFrame[idx] = f
            Out.emit(["event": "snap_back", "index": idx, "frame": topLeftArray(f)])
        }
        snapTimers[idx] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    func windowDidMiniaturize(_ n: Notification) {
        if let i = index(of: n) { Out.emit(["event": "minimized", "index": i]) }
    }
    func windowDidDeminiaturize(_ n: Notification) {
        if let i = index(of: n) { Out.emit(["event": "unminimized", "index": i]) }
    }
    func windowDidEnterFullScreen(_ n: Notification) {
        if let i = index(of: n) { Out.emit(["event": "fullscreen", "index": i, "state": "entered"]) }
    }
    func windowDidExitFullScreen(_ n: Notification) {
        if let i = index(of: n) { Out.emit(["event": "fullscreen", "index": i, "state": "exited"]) }
    }
    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let i = indexOf[ObjectIdentifier(w)] else { return }
        indexOf[ObjectIdentifier(w)] = nil
        windows[i] = nil
        snapTimers[i]?.cancel()
        slowTimers[i]?.cancel()
        Out.emit(["event": "closed", "index": i, "windowNumber": w.windowNumber])
    }

    func applicationDidHide(_ notification: Notification) { Out.emit(["event": "hidden"]) }
    func applicationDidUnhide(_ notification: Notification) { Out.emit(["event": "unhidden"]) }

    // MARK: control channel

    private func startStdinReader() {
        let t = Thread { [weak self] in
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                DispatchQueue.main.async { self?.handle(trimmed) }
            }
            DispatchQueue.main.async { self?.quit(reason: "stdin EOF") }
        }
        t.name = "fixture-stdin"
        t.start()
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ").map(String.init)
        let cmd = parts[0]
        let arg = parts.count > 1 ? Int(parts[1]) : nil
        var ack: [String: Any] = ["event": "ack", "cmd": cmd, "line": line, "ok": true]
        if let arg { ack["arg"] = arg }
        func fail(_ msg: String) { ack["ok"] = false; ack["error"] = msg }
        func target() -> NSWindow? {
            guard let arg else { fail("\(cmd) needs a window index"); return nil }
            guard let w = windows[arg] else { fail("no window \(arg)"); return nil }
            return w
        }

        switch cmd {
        case "open":
            ack["index"] = openWindow()
        case "close":
            target()?.close()
        case "minimize":
            if let w = target() {
                w.miniaturize(nil)
                // Some setups (seen with Stage Manager on) silently refuse; say so.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if !w.isMiniaturized && w.isVisible { Out.emit(["event": "minimize_failed", "index": arg ?? -1]) }
                }
            }
        case "unminimize":
            target()?.deminiaturize(nil)
        case "fullscreen":
            target()?.toggleFullScreen(nil)
        case "hide":
            NSApp.hide(nil)
        case "unhide":
            NSApp.unhide(nil)
        case "focus":
            if let w = target() {
                (NSApp as LegacyActivation).activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
            }
        case "frames":
            var frames: [String: Any] = [:]
            for (i, w) in windows { frames[String(i)] = topLeftArray(w.frame) }
            ack["frames"] = frames
        case "quit":
            Out.emit(ack)
            quit(reason: "quit command")
            return
        default:
            fail("unknown command")
        }
        Out.emit(ack)
    }

    private func quit(reason: String) {
        guard !quitting else { return }
        quitting = true
        for w in windows.values { w.orderOut(nil) }
        for w in tabs + aux { w.orderOut(nil) }
        Out.emit(["event": "exit", "reason": reason])
        exit(0)
    }
}
