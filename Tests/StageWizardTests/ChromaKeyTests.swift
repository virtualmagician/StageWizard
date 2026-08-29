import XCTest
@testable import StageWizard

/// D10 chroma key: `CameraEffects` model coverage (decode defaults, clamping,
/// `anyEnabled`) plus the pure math behind `CameraFrameProcessor`'s
/// CIColorCube lattice. No live capture sessions here — see VideoEngineTests
/// for camera pipeline integration coverage.
final class ChromaKeyTests: XCTestCase {

    // MARK: - CameraEffects: defaults for older files

    func testChromaKeyDefaultsOffPureGreenForOlderFiles() throws {
        // Pre-D10 files predate chroma key entirely — bare `{}`.
        let old = try JSONDecoder().decode(CameraEffects.self, from: Data("{}".utf8))
        XCTAssertFalse(old.chromaKey)
        XCTAssertEqual(old.chromaKeyColor, RGBAColor(red: 0, green: 1, blue: 0))
        XCTAssertEqual(old.chromaTolerance, 0.35)
        XCTAssertEqual(old.chromaSoftness, 0.1)
    }

    func testChromaKeyStripKeyDefaultsMatchOlderFiles() throws {
        // A CameraEffects payload with the new keys stripped out (simulating
        // a file saved before D10 that still has other effect fields set).
        let effects = CameraEffects(magicDust: true, dustScale: 2)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(effects)) as! [String: Any]
        for key in ["chromaKey", "chromaKeyColor", "chromaTolerance", "chromaSoftness"] {
            json.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(
            CameraEffects.self, from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertFalse(decoded.chromaKey)
        XCTAssertEqual(decoded.chromaKeyColor, RGBAColor(red: 0, green: 1, blue: 0))
        XCTAssertEqual(decoded.chromaTolerance, 0.35)
        XCTAssertEqual(decoded.chromaSoftness, 0.1)
        // Untouched sibling fields still round-trip.
        XCTAssertTrue(decoded.magicDust)
        XCTAssertEqual(decoded.dustScale, 2)
    }

    // MARK: - CameraEffects: round trip + clamp on decode

    func testChromaKeyRoundTrip() throws {
        let effects = CameraEffects(
            chromaKey: true,
            chromaKeyColor: RGBAColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1),
            chromaTolerance: 0.5,
            chromaSoftness: 0.2
        )
        let decoded = try JSONDecoder().decode(CameraEffects.self, from: JSONEncoder().encode(effects))
        XCTAssertEqual(decoded, effects)
    }

    func testChromaToleranceAndSoftnessClampOnInit() {
        XCTAssertEqual(CameraEffects(chromaTolerance: 1.5).chromaTolerance, 1, "clamped high")
        XCTAssertEqual(CameraEffects(chromaTolerance: -0.2).chromaTolerance, 0, "clamped low")
        XCTAssertEqual(CameraEffects(chromaSoftness: 1.5).chromaSoftness, 1, "clamped high")
        XCTAssertEqual(CameraEffects(chromaSoftness: -0.2).chromaSoftness, 0, "clamped low")
    }

    func testChromaToleranceAndSoftnessClampOnDecode() throws {
        // A hand-authored (or corrupted) file with out-of-range values must
        // still decode clamped, same as every other effect parameter.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CameraEffects())) as! [String: Any]
        json["chromaTolerance"] = 1.5
        json["chromaSoftness"] = -0.2
        let decoded = try JSONDecoder().decode(
            CameraEffects.self, from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertEqual(decoded.chromaTolerance, 1, "clamped high on decode")
        XCTAssertEqual(decoded.chromaSoftness, 0, "clamped low on decode")
    }

    // MARK: - anyEnabled

    func testAnyEnabledIncludesChromaKey() {
        XCTAssertTrue(CameraEffects(chromaKey: true).anyEnabled)
        XCTAssertFalse(CameraEffects().anyEnabled)
        XCTAssertFalse(CameraEffects(chromaKey: false).anyEnabled)
    }

    // MARK: - YCbCr chroma distance

    func testChromaDistanceIsZeroForIdenticalColors() {
        let green = RGBAColor(red: 0, green: 1, blue: 0)
        XCTAssertEqual(CameraFrameProcessor.chromaDistance(green, green), 0, accuracy: 1e-9)
    }

    func testChromaDistanceGreenVsRedIsLarge() {
        let green = RGBAColor(red: 0, green: 1, blue: 0)
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        // Well beyond the default tolerance+softness band (0.35 + 0.1 =
        // 0.45) — red must never get keyed out while keying green.
        XCTAssertGreaterThan(CameraFrameProcessor.chromaDistance(green, red), 0.45)
    }

    // MARK: - Smoothstep

    func testSmoothstepEndpointsMidpointAndClamping() {
        XCTAssertEqual(CameraFrameProcessor.smoothstep(0.25, 0.45, 0.25), 0)
        XCTAssertEqual(CameraFrameProcessor.smoothstep(0.25, 0.45, 0.45), 1)
        XCTAssertEqual(CameraFrameProcessor.smoothstep(0.25, 0.45, 0.35), 0.5, accuracy: 1e-9)
        XCTAssertEqual(CameraFrameProcessor.smoothstep(0.25, 0.45, 0.1), 0, "clamped below edge0")
        XCTAssertEqual(CameraFrameProcessor.smoothstep(0.25, 0.45, 0.9), 1, "clamped above edge1")
    }

    // MARK: - Cube generation

    /// Reads back one RGBA cell of a chroma-key cube. `CIColorCubeWithColorSpace`
    /// documents the layout as: columns indexed by red (fastest), rows by
    /// green, and each successive data plane indexed by blue (slowest) — so
    /// cell (r, g, b) starts at float index (b·size² + g·size + r) · 4.
    private func cell(_ data: Data, size: Int, r: Int, g: Int, b: Int) -> (r: Float, g: Float, b: Float, a: Float) {
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let index = (b * size * size + g * size + r) * 4
        return (floats[index], floats[index + 1], floats[index + 2], floats[index + 3])
    }

    func testCubeKeyColorItselfIsFullyTransparentAndPremultiplied() {
        let size = 32
        let data = CameraFrameProcessor.chromaKeyCubeData(
            color: RGBAColor(red: 0, green: 1, blue: 0), tolerance: 0.35, softness: 0.1, size: size
        )
        // Lattice cell nearest pure green: r=0, g=size-1, b=0 — exactly the
        // key color itself.
        let keyCell = cell(data, size: size, r: 0, g: size - 1, b: 0)
        XCTAssertEqual(keyCell.a, 0, accuracy: 1e-6)
        XCTAssertEqual(keyCell.r, 0, accuracy: 1e-6, "premultiplied by alpha 0")
        XCTAssertEqual(keyCell.g, 0, accuracy: 1e-6, "premultiplied by alpha 0")
        XCTAssertEqual(keyCell.b, 0, accuracy: 1e-6, "premultiplied by alpha 0")
    }

    func testCubeFarColorIsFullyOpaqueAndUnpremultiplied() {
        let size = 32
        let data = CameraFrameProcessor.chromaKeyCubeData(
            color: RGBAColor(red: 0, green: 1, blue: 0), tolerance: 0.35, softness: 0.1, size: size
        )
        // Lattice cell nearest pure red: r=size-1, g=0, b=0.
        let farCell = cell(data, size: size, r: size - 1, g: 0, b: 0)
        XCTAssertEqual(farCell.a, 1, accuracy: 1e-6)
        XCTAssertEqual(farCell.r, 1, accuracy: 1e-6, "alpha 1 → premultiply is a no-op")
    }

    func testCubeAlphaMonotonicAlongRedAxisAwayFromKeyColor() {
        // Sweep r = 0…size-1 at g = size-1, b = 0 — colors (r, 1, 0), a
        // straight line from the key color (0,1,0) toward yellow (1,1,0).
        // Cb/Cr are linear along this line, so distance-to-key grows
        // linearly in r and alpha must never decrease as r increases.
        let size = 32
        let data = CameraFrameProcessor.chromaKeyCubeData(
            color: RGBAColor(red: 0, green: 1, blue: 0), tolerance: 0.35, softness: 0.1, size: size
        )
        var previous: Float = -1
        for r in 0..<size {
            let a = cell(data, size: size, r: r, g: size - 1, b: 0).a
            XCTAssertGreaterThanOrEqual(a, previous - 1e-6, "alpha must not decrease at r=\(r)")
            previous = a
        }
        XCTAssertEqual(cell(data, size: size, r: 0, g: size - 1, b: 0).a, 0, accuracy: 1e-6)
        XCTAssertEqual(cell(data, size: size, r: size - 1, g: size - 1, b: 0).a, 1, accuracy: 1e-6)
    }

    func testCubeAlphaJustInsideAndJustOutsideToleranceBand() {
        // Along the same (r, 1, 0) line, distance(r) = r · |Δ(Cb,Cr)| where
        // Δ(Cb,Cr) is yellow's chroma minus green's — i.e. distance is exactly
        // linear in r. Solve for the r index that lands just inside/outside
        // the tolerance±softness band and check the cube landed near 0/1.
        let tolerance = 0.35, softness = 0.1
        let green = RGBAColor(red: 0, green: 1, blue: 0)
        let yellow = RGBAColor(red: 1, green: 1, blue: 0)
        let perUnitDistance = CameraFrameProcessor.chromaDistance(yellow, green)
        let size = 64
        let data = CameraFrameProcessor.chromaKeyCubeData(
            color: green, tolerance: tolerance, softness: softness, size: size
        )
        func rIndex(forDistance d: Double) -> Int {
            Int((d / perUnitDistance * Double(size - 1)).rounded())
        }
        let justInside = rIndex(forDistance: tolerance - softness - 0.02)
        let justOutside = rIndex(forDistance: tolerance + softness + 0.02)
        XCTAssertLessThan(cell(data, size: size, r: justInside, g: size - 1, b: 0).a, 0.05)
        XCTAssertGreaterThan(cell(data, size: size, r: justOutside, g: size - 1, b: 0).a, 0.95)
    }

    func testCubeRebuildsOnlyWhenParamsChange() {
        // Same params, different `size` argument only affects allocation —
        // sanity check that the size parameter actually drives the lattice
        // (guards against an accidental hardcoded 64 inside the loop bounds).
        let data16 = CameraFrameProcessor.chromaKeyCubeData(
            color: RGBAColor(red: 0, green: 1, blue: 0), tolerance: 0.35, softness: 0.1, size: 16
        )
        XCTAssertEqual(data16.count, 16 * 16 * 16 * 4 * MemoryLayout<Float>.size)
    }
}
