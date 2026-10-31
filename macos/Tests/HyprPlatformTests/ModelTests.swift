import ApplicationServices
import CoreGraphics
import Testing
@testable import HyprPlatform

@Suite struct ModelTests {

    @Test func windowStateRawValuesMirrorCore() {
        #expect(WindowState.tiled.rawValue == 0)
        #expect(WindowState.floating.rawValue == 1)
        #expect(WindowState.minimized.rawValue == 2)
        #expect(WindowState.fullscreen.rawValue == 3)
        #expect(WindowState.hidden.rawValue == 4)
    }

    @Test func ghostStates() {
        #expect(WindowState.allCases.filter(\.isGhost) == [.minimized, .fullscreen, .hidden])
    }

    @Test func windowRefIdentityIncludesPid() {
        let a = WindowRef(pid: 1, windowID: 42), b = WindowRef(pid: 2, windowID: 42)
        #expect(a != b)
        #expect(Set([a, b, WindowRef(pid: 1, windowID: 42)]).count == 2)
        #expect(a.description == "1:42")
    }

    @Test(arguments: [
        (AXError.cannotComplete, AXBackendError.cannotComplete),
        (.invalidUIElement, .invalidUIElement),
        (.attributeUnsupported, .attributeUnsupported),
        (.notImplemented, .notImplemented),
        (.apiDisabled, .apiDisabled),
        (.noValue, .noValue),
        (.failure, .other(AXError.failure.rawValue)),
    ])
    func axErrorMapping(_ ax: AXError, _ expected: AXBackendError) {
        #expect(AXBackendError(ax) == expected)
    }

    @Test func onlyCannotCompleteIsRetryable() {
        #expect(AXBackendError.cannotComplete.isRetryable)
        #expect(!AXBackendError.invalidUIElement.isRetryable)
        #expect(!AXBackendError.apiDisabled.isRetryable)
    }

    @Test func identityMapStableForSameRef() {
        let m = WindowIdentityMap()
        let r = WindowRef(pid: 10, windowID: 77)
        #expect(m.engineID(for: r) == 77)
        #expect(m.engineID(for: r) == 77)
        #expect(m.ref(forEngineID: 77) == r)
    }

    /// Quirk 13: a window id reused after an app relaunch gets a new generation.
    @Test func identityMapBumpsGenerationOnReuse() {
        let m = WindowIdentityMap()
        let old = WindowRef(pid: 10, windowID: 77), new = WindowRef(pid: 11, windowID: 77)
        let a = m.engineID(for: old), b = m.engineID(for: new)
        #expect(a != b)
        #expect(b == (1 << 32) | 77)
        #expect(m.ref(forEngineID: b) == new)
        m.forget(engineID: b)
        #expect(m.ref(forEngineID: b) == nil)
    }

    @Test func rectApproximateEquality() {
        let r = rect(10, 10, 100, 100)
        #expect(r.isApproximately(rect(10.4, 9.6, 100.5, 99.5), tolerance: 0.5))
        #expect(!r.isApproximately(rect(12, 10, 100, 100), tolerance: 1))
    }
}
