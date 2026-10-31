import CoreGraphics
import Foundation
import Testing
@testable import HyprPlatform

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [PlatformEvent] = []
    func add(_ e: PlatformEvent) { lock.lock(); list.append(e); lock.unlock() }
    var all: [PlatformEvent] { lock.lock(); defer { lock.unlock() }; return list }
}

@Suite struct ObserverHubTests {
    func makeHub(_ reg: FakeAXObserverRegistrar, _ sched: FakeDelayScheduler, _ box: EventBox) -> AXObserverHub {
        AXObserverHub(registrar: reg, scheduler: sched, emit: box.add)
    }

    @Test func retryScheduleIs50_150_400_1000ms() {
        #expect(ObserverRetrySchedule.delays == [0.05, 0.15, 0.4, 1.0])
    }

    @Test func registersImmediatelyWhenReady() {
        let reg = FakeAXObserverRegistrar(), sched = FakeDelayScheduler(), box = EventBox()
        let hub = makeHub(reg, sched, box)
        hub.observe(pid: 1)
        #expect(hub.observedPids == [1])
        #expect(sched.requestedDelays.isEmpty)
    }

    @Test func retriesWithBackoffUntilRegistered() {
        let reg = FakeAXObserverRegistrar(), sched = FakeDelayScheduler(), box = EventBox()
        reg.failuresBeforeSuccess[1] = 2
        let hub = makeHub(reg, sched, box)
        hub.observe(pid: 1)
        #expect(hub.observedPids.isEmpty)
        sched.runAll()
        #expect(sched.requestedDelays == [0.05, 0.15])
        #expect(reg.attempts == [1, 1, 1])
        #expect(hub.observedPids == [1])
        #expect(box.all.isEmpty)
    }

    @Test func givesUpAfterFullScheduleAndReports() {
        let reg = FakeAXObserverRegistrar(), sched = FakeDelayScheduler(), box = EventBox()
        reg.failuresBeforeSuccess[1] = .max
        let hub = makeHub(reg, sched, box)
        hub.observe(pid: 1)
        sched.runAll()
        #expect(sched.requestedDelays == [0.05, 0.15, 0.4, 1.0])
        #expect(reg.attempts.count == 5)
        #expect(box.all == [.observerRegistrationFailed(1)])
        #expect(hub.observedPids.isEmpty)
        // A later observe (e.g. next launch notification) starts over.
        reg.failuresBeforeSuccess[1] = 0
        hub.observe(pid: 1)
        #expect(hub.observedPids == [1])
    }

    @Test func stopDuringRetryAbandonsIt() {
        let reg = FakeAXObserverRegistrar(), sched = FakeDelayScheduler(), box = EventBox()
        reg.failuresBeforeSuccess[1] = 1
        let hub = makeHub(reg, sched, box)
        hub.observe(pid: 1)
        hub.stopObserving(pid: 1)
        sched.runAll()
        #expect(reg.attempts == [1])
        #expect(hub.observedPids.isEmpty)
    }

    @Test func observeIsIdempotentAndStopUnregisters() {
        let reg = FakeAXObserverRegistrar(), sched = FakeDelayScheduler(), box = EventBox()
        let hub = makeHub(reg, sched, box)
        hub.observe(pid: 1)
        hub.observe(pid: 1)
        #expect(reg.attempts == [1])
        hub.stopObserving(pid: 1)
        #expect(reg.unregistered == [1])
        #expect(!reg.fire(.appHidden(1), pid: 1))
    }

    @Test func forwardsObserverEvents() {
        let reg = FakeAXObserverRegistrar(), sched = FakeDelayScheduler(), box = EventBox()
        let hub = makeHub(reg, sched, box)
        hub.observe(pid: 7)
        let w = WindowRef(pid: 7, windowID: 3)
        #expect(reg.fire(.window(.moved, pid: 7, window: w), pid: 7))
        #expect(box.all == [.window(.moved, pid: 7, window: w)])
    }
}

@Suite struct NotificationMappingTests {
    @Test(arguments: [
        ("AXWindowCreated", WindowEventKind.created), ("AXUIElementDestroyed", .destroyed),
        ("AXFocusedWindowChanged", .focused), ("AXMainWindowChanged", .mainChanged),
        ("AXWindowMoved", .moved), ("AXWindowResized", .resized),
        ("AXWindowMiniaturized", .miniaturized), ("AXWindowDeminiaturized", .deminiaturized),
    ])
    func windowNotifications(_ name: String, _ kind: WindowEventKind) {
        let r = WindowRef(pid: 5, windowID: 9)
        #expect(AXNotificationName.event(for: name, pid: 5, window: r) == .window(kind, pid: 5, window: r))
    }

    @Test func appNotificationsAndUnknown() {
        #expect(AXNotificationName.event(for: "AXApplicationHidden", pid: 5, window: nil) == .appHidden(5))
        #expect(AXNotificationName.event(for: "AXApplicationShown", pid: 5, window: nil) == .appShown(5))
        #expect(AXNotificationName.event(for: "AXApplicationActivated", pid: 5, window: nil) == .appActivated(5))
        #expect(AXNotificationName.event(for: "AXTitleChanged", pid: 5, window: nil) == nil)
    }

    @Test func everyRegisteredNotificationMaps() {
        for n in AXNotificationName.appLevel + AXNotificationName.windowLevel {
            #expect(AXNotificationName.event(for: n, pid: 1, window: nil) != nil)
        }
    }

    @Test func syntheticMarker() {
        #expect(SyntheticEventMarker.isSynthetic(userData: SyntheticEventMarker.value))
        #expect(!SyntheticEventMarker.isSynthetic(userData: 0))
    }
}

@Suite struct PlatformEventsTests {
    @Test func observesRegularAppsAndDeliversOnCallerQueue() {
        let desk = makeDesk()
        desk.addApp(pid: 200, bundleID: "com.example.menubar", policy: .accessory)
        desk.addApp(pid: 300, bundleID: WindowEligibility.ownBundleID)
        let reg = FakeAXObserverRegistrar()
        let mouse = FakeMouseMonitor()
        let queue = DispatchQueue(label: "test.events")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let box = EventBox()
        var onQueue = true
        let events = PlatformEvents(queue: queue, registrar: reg, apps: desk.apps, mouse: mouse) { e in
            if DispatchQueue.getSpecific(key: key) != true { onQueue = false }
            box.add(e)
        }
        events.start()
        #expect(events.hub.observedPids == [100])
        #expect(mouse.isRunning)
        mouse.simulate(.userDragBegan(CGPoint(x: 1, y: 2)))
        reg.fire(.window(.created, pid: 100, window: nil), pid: 100)
        queue.sync {}
        #expect(box.all == [.userDragBegan(CGPoint(x: 1, y: 2)), .window(.created, pid: 100, window: nil)])
        #expect(onQueue)
        events.stop()
        #expect(!mouse.isRunning)
        #expect(events.hub.observedPids.isEmpty)
    }

    @Test func fakeDesktopEmitsEventsForMutations() {
        let desk = makeDesk(spaces: 2)
        let box = EventBox()
        desk.eventHandler = box.add
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500))
        try? desk.ax.setPosition(CGPoint(x: 10, y: 30), of: w)
        desk.setMinimized(w, true)
        desk.setActiveSpace(2, display: 1)
        desk.closeWindow(w)
        #expect(box.all == [
            .window(.created, pid: 100, window: w), .window(.moved, pid: 100, window: w),
            .window(.miniaturized, pid: 100, window: w), .activeSpaceChanged, .window(.destroyed, pid: 100, window: w),
        ])
    }
}
