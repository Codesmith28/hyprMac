import AppKit

extension Catalog {
    // MARK: small windows float (default thresholds 400 x 300)

    static let floatSmall = Scenario(name: "float-small",
                                     summary: "a 300x200 window keeps its frame; the others tile as 2") { ctx in
        try ctx.startHypr()
        let log = try ctx.log
        let c = log.cursor
        let f = try ctx.launchFixture(3, ["--size", "300x200@1"])
        let r = try (0..<3).map(f.ref)
        guard let orig = f.originalFrame(1) else { throw HarnessError("fixture did not report window 1's frame") }
        guard log.waitFor("floated", after: c, timeout: 6, where: { $0.string("reason") == "small" }) != nil else {
            throw HarnessError("hyprMac never logged a `floated` event for the small window", details: log.tail())
        }
        let variants = ctx.oracle(2).map { [$0[0], orig, $0[1]] }
        try ctx.expect(r, variants: variants, "windows 0 and 2 tiled as 2, small window 1 untouched")
    }
}
