import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import HyprPlatform

@Suite struct AXDecodingTests {
    func axError(_ e: AXError) -> CFTypeRef {
        var err = e
        return AXValueCreate(.axError, &err)!
    }
    func axPoint(_ x: CGFloat, _ y: CGFloat) -> CFTypeRef { var p = CGPoint(x: x, y: y); return AXValueCreate(.cgPoint, &p)! }
    func axSize(_ w: CGFloat, _ h: CGFloat) -> CFTypeRef { var s = CGSize(width: w, height: h); return AXValueCreate(.cgSize, &s)! }

    /// role, subrole, title, position, size, minimized, fullscreen, main, focused, closeButton, minimumSize
    func values(subrole: CFTypeRef? = "AXStandardWindow" as CFString, position: CFTypeRef? = nil,
                close: CFTypeRef? = AXUIElementCreateApplication(getpid()), minSize: CFTypeRef? = nil,
                fullscreen: CFTypeRef = kCFBooleanFalse) -> [CFTypeRef?] {
        ["AXWindow" as CFString, subrole, "Doc" as CFString, position ?? axPoint(10, 20), axSize(800, 600),
         kCFBooleanFalse, fullscreen, kCFBooleanTrue, kCFBooleanTrue, close, minSize]
    }

    @Test func attributeListIsOneCallInFixedOrder() {
        #expect(AXDecoding.factAttributes.count == 11)
        #expect(AXDecoding.factAttributes.first == "AXRole")
        #expect(AXDecoding.factAttributes.last == "AXMinimumSize")
    }

    @Test func slotErrorsAreRecognised() {
        #expect(AXDecoding.slotError(axError(.cannotComplete)) == .cannotComplete)
        #expect(AXDecoding.slotError(axError(.noValue)) == .noValue)
        #expect(AXDecoding.slotError(axPoint(1, 2)) == nil)
        #expect(AXDecoding.slotError("AXWindow" as CFString) == nil)
        #expect(AXDecoding.slotError(nil) == nil)
    }

    @Test func decodesFullFacts() throws {
        let d = try AXDecoding.decodeFacts(values(minSize: axSize(300, 200), fullscreen: kCFBooleanTrue))
        #expect(d == AXDecoding.DecodedFacts(role: "AXWindow", subrole: "AXStandardWindow", title: "Doc",
                                             frame: CGRect(x: 10, y: 20, width: 800, height: 600),
                                             isMinimized: false, isFullscreen: true, isMain: true, isFocused: true,
                                             hasCloseButton: true, minSize: CGSize(width: 300, height: 200)))
    }

    @Test func missingOptionalSlotsDecodeAsAbsent() throws {
        let d = try AXDecoding.decodeFacts(values(subrole: axError(.noValue), close: axError(.attributeUnsupported),
                                                  minSize: axError(.noValue)))
        #expect(d.subrole == nil)
        #expect(!d.hasCloseButton)
        #expect(d.minSize == nil)
    }

    /// A hung app must cost one timeout: any slot saying cannotComplete aborts the window.
    @Test func cannotCompleteInAnySlotPropagates() {
        #expect(throws: AXBackendError.cannotComplete) { try AXDecoding.decodeFacts(values(subrole: axError(.cannotComplete))) }
        #expect(throws: AXBackendError.invalidUIElement) { try AXDecoding.decodeFacts(values(close: axError(.invalidUIElement))) }
    }

    @Test func missingFrameIsNoValue() {
        #expect(throws: AXBackendError.noValue) { try AXDecoding.decodeFacts(values(position: axError(.noValue))) }
        #expect(throws: AXBackendError.noValue) { try AXDecoding.decodeFacts([]) }
    }

    /// Review #7: a cached element of a quit app reports cannotComplete; that means "gone".
    @Test func deadPidTurnsCannotCompleteIntoGone() {
        #expect(AXDecoding.classify(.cannotComplete, pidAlive: { false }) == .invalidUIElement)
        #expect(AXDecoding.classify(.cannotComplete, pidAlive: { true }) == .cannotComplete)
        #expect(AXDecoding.classify(.noValue, pidAlive: { false }) == .noValue)
        #expect(AXDecoding.isAlive(getpid()))
        #expect(!AXDecoding.isAlive(99_999_999))
        #expect(!AXDecoding.isAlive(0))
    }

    // MARK: parent walk (review #4)

    struct Node { var role: String; var window: Int?; var parent: Int?; var id: CGWindowID? }

    func resolve(_ tree: [Node], from i: Int, depth: Int = 6) -> (id: CGWindowID, isSelf: Bool)? {
        AXDecoding.resolveWindow(i, maxDepth: depth, role: { tree[$0].role }, windowAttribute: { tree[$0].window },
                                 parent: { tree[$0].parent }, windowID: { tree[$0].id })
    }

    @Test func windowItself() {
        let r = resolve([Node(role: "AXWindow", window: nil, parent: nil, id: 9)], from: 0)
        #expect(r?.id == 9 && r?.isSelf == true)
    }

    @Test func windowAttribute() {
        let t = [Node(role: "AXButton", window: 1, parent: nil, id: nil), Node(role: "AXWindow", window: nil, parent: nil, id: 4)]
        #expect(resolve(t, from: 0)?.id == 4)
        #expect(resolve(t, from: 0)?.isSelf == false)
    }

    /// Ghostty: the titlebar is an AXGroup without kAXWindow; its parent chain reaches the window.
    @Test func ghosttyGroupResolvesThroughParents() {
        let t = [Node(role: "AXGroup", window: nil, parent: 1, id: nil),
                 Node(role: "AXGroup", window: nil, parent: 2, id: nil),
                 Node(role: "AXWindow", window: nil, parent: 3, id: 9452),
                 Node(role: "AXApplication", window: nil, parent: nil, id: nil)]
        #expect(resolve(t, from: 0)?.id == 9452)
    }

    @Test func walkStopsAtApplicationAndDepthLimit() {
        let app = [Node(role: "AXGroup", window: nil, parent: 1, id: nil), Node(role: "AXApplication", window: nil, parent: nil, id: nil)]
        #expect(resolve(app, from: 0) == nil)
        var deep = (0..<8).map { Node(role: "AXGroup", window: nil, parent: $0 + 1, id: nil) }
        deep.append(Node(role: "AXWindow", window: nil, parent: nil, id: 1))
        #expect(resolve(deep, from: 0) == nil)          // 8 levels up: beyond the limit
        #expect(resolve(deep, from: 0, depth: 8)?.id == 1)
        // An AXWindow without a resolvable id keeps walking (and gives up).
        #expect(resolve([Node(role: "AXWindow", window: nil, parent: nil, id: nil)], from: 0) == nil)
    }

    @Test func systemBackendInitSetsGlobalTimeoutSafely() {
        let ax = SystemAXBackend(messagingTimeout: 0.25)
        ax.setMessagingTimeout(pid: getpid(), seconds: 5) // documented no-op
        ax.forget(pid: getpid())
        #expect(SystemAXBackend.defaultMessagingTimeout == 0.25)
    }
}
