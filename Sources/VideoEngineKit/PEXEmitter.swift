import AppKit
import Compression
import QuartzCore

/// The .pex presets bundled with the app (Support/presets → Resources).
public enum DustPresets {
    /// Preset display names, alphabetical ("White", "MagicFire", …).
    @MainActor
    public static let names: [String] = {
        (Bundle.main.urls(forResourcesWithExtension: "pex", subdirectory: "presets") ?? [])
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }()

    @MainActor
    public static func url(for name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "pex", subdirectory: "presets")
    }

    /// The preset used when a cue names none.
    @MainActor
    public static var defaultName: String { names.first ?? "White" }
}

/// Particle Designer `.pex` emitter support — parsed with Foundation's
/// XMLParser and mapped onto Apple's CAEmitterLayer (zero dependencies).
/// Gravity-type emitters (the common case) map with full fidelity; radial
/// emitters are approximated. The embedded texture (base64 + gzip) is
/// decoded with the Compression framework; a code-drawn soft sparkle is the
/// fallback (and the built-in default when no .pex is chosen).
public struct PEXEmitterConfig: Sendable {
    public struct PEXColor: Sendable {
        public var red: Double = 1, green: Double = 1, blue: Double = 1, alpha: Double = 1
    }

    public var maxParticles: Double = 100
    public var particleLifeSpan: Double = 1
    public var particleLifespanVariance: Double = 0
    public var speed: Double = 50
    public var speedVariance: Double = 0
    public var angle: Double = 90
    public var angleVariance: Double = 360
    public var gravityX: Double = 0
    public var gravityY: Double = 0
    public var startParticleSize: Double = 20
    public var startParticleSizeVariance: Double = 0
    public var finishParticleSize: Double = 20
    public var finishParticleSizeVariance: Double = 0
    public var rotationStart: Double = 0
    public var rotationStartVariance: Double = 0
    public var rotationEnd: Double = 0
    public var rotationEndVariance: Double = 0
    public var duration: Double = -1
    public var emitterType: Int = 0
    public var yCoordFlipped: Int = 1
    public var blendFuncSource: Int = 770
    public var blendFuncDestination: Int = 1
    public var startColor = PEXColor()
    public var startColorVariance = PEXColor(red: 0, green: 0, blue: 0, alpha: 0)
    public var finishColor = PEXColor(red: 0, green: 0, blue: 0, alpha: 0)
    /// Decoded embedded texture, if the file carried one.
    public var texture: CGImage?

    /// GL_SRC_ALPHA + GL_ONE — the glowing look. CAEmitterLayer can't do GL
    /// blend funcs; callers may approximate (we keep normal alpha, which
    /// reads fine for dust/sparkle particles).
    public var isAdditive: Bool { blendFuncSource == 770 && blendFuncDestination == 1 }

    // MARK: - Parsing

    public static func parse(data: Data) -> PEXEmitterConfig? {
        let collector = PEXCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() || !collector.elements.isEmpty else { return nil }
        guard !collector.elements.isEmpty else { return nil }
        let e = collector.elements

        func value(_ name: String, _ fallback: Double) -> Double {
            Double(e[name.lowercased()]?["value"] ?? "") ?? fallback
        }
        func pair(_ name: String) -> (Double, Double) {
            let attrs = e[name.lowercased()]
            return (Double(attrs?["x"] ?? "") ?? 0, Double(attrs?["y"] ?? "") ?? 0)
        }
        func color(_ name: String, _ fallback: PEXColor) -> PEXColor {
            guard let attrs = e[name.lowercased()] else { return fallback }
            return PEXColor(
                red: Double(attrs["red"] ?? "") ?? fallback.red,
                green: Double(attrs["green"] ?? "") ?? fallback.green,
                blue: Double(attrs["blue"] ?? "") ?? fallback.blue,
                alpha: Double(attrs["alpha"] ?? "") ?? fallback.alpha
            )
        }

        var config = PEXEmitterConfig()
        config.maxParticles = value("maxParticles", 100)
        config.particleLifeSpan = value("particleLifeSpan", 1)
        config.particleLifespanVariance = value("particleLifespanVariance", 0)
        config.speed = value("speed", 50)
        config.speedVariance = value("speedVariance", 0)
        config.angle = value("angle", 90)
        config.angleVariance = value("angleVariance", 360)
        (config.gravityX, config.gravityY) = pair("gravity")
        config.startParticleSize = value("startParticleSize", 20)
        config.startParticleSizeVariance = value("startParticleSizeVariance", 0)
        config.finishParticleSize = value("finishParticleSize", config.startParticleSize)
        config.finishParticleSizeVariance = value("finishParticleSizeVariance", 0)
        config.rotationStart = value("rotationStart", 0)
        config.rotationStartVariance = value("rotationStartVariance", 0)
        config.rotationEnd = value("rotationEnd", 0)
        config.rotationEndVariance = value("rotationEndVariance", 0)
        config.duration = value("duration", -1)
        config.emitterType = Int(value("emitterType", 0))
        config.yCoordFlipped = Int(value("yCoordFlipped", 1))
        config.blendFuncSource = Int(value("blendFuncSource", 770))
        config.blendFuncDestination = Int(value("blendFuncDestination", 1))
        config.startColor = color("startColor", PEXColor())
        config.startColorVariance = color("startColorVariance", PEXColor(red: 0, green: 0, blue: 0, alpha: 0))
        config.finishColor = color("finishColor", PEXColor(red: 0, green: 0, blue: 0, alpha: 0))

        if let base64 = e["texture"]?["data"],
           let compressed = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
           let decoded = gunzip(compressed),
           let source = CGImageSourceCreateWithData(decoded as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            config.texture = image
        }
        return config
    }

    public static func parse(url: URL) -> PEXEmitterConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data)
    }

    private final class PEXCollector: NSObject, XMLParserDelegate {
        var elements: [String: [String: String]] = [:]

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String]
        ) {
            guard !attributes.isEmpty else { return }
            elements[elementName.lowercased()] = attributes
        }
    }

    /// gzip → raw DEFLATE via the Compression framework (zero-dependency):
    /// strip the RFC 1952 header/trailer, inflate the middle.
    static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1f,
              data[data.startIndex + 1] == 0x8b,
              data[data.startIndex + 2] == 8 else { return nil }
        let flags = data[data.startIndex + 3]
        var index = data.startIndex + 10
        if flags & 0x04 != 0 {   // FEXTRA
            guard index + 2 <= data.endIndex else { return nil }
            let xlen = Int(data[index]) | (Int(data[index + 1]) << 8)
            index += 2 + xlen
        }
        if flags & 0x08 != 0 {   // FNAME (null-terminated)
            while index < data.endIndex, data[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x10 != 0 {   // FCOMMENT
            while index < data.endIndex, data[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }   // FHCRC
        guard index < data.endIndex - 8 else { return nil }

        // Uncompressed size lives in the little-endian trailer.
        let sizeBytes = data.suffix(4)
        let expectedSize = sizeBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let capacity = min(max(Int(expectedSize), 64), 64 * 1024 * 1024)

        let deflated = data.subdata(in: index..<(data.endIndex - 8))
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { outBytes -> Int in
            deflated.withUnsafeBytes { inBytes -> Int in
                compression_decode_buffer(
                    outBytes.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    inBytes.bindMemory(to: UInt8.self).baseAddress!, deflated.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        output.removeSubrange(written..<output.count)
        return output
    }

    // MARK: - CAEmitterLayer mapping

    /// Build a configured emitter layer, ready to position. `birthRate` on
    /// the LAYER is the on/off tap (0 = off), so hands can vanish and the
    /// already-born dust winds down naturally.
    @MainActor
    public func makeEmitterLayer(sizeScale: Double = 1) -> CAEmitterLayer {
        let cell = CAEmitterCell()
        let life = max(particleLifeSpan, 0.05)
        let textureImage = texture ?? Self.builtinSparkleTexture
        let textureSize = Double(textureImage.width)

        cell.contents = textureImage
        cell.birthRate = Float(maxParticles / life)
        cell.lifetime = Float(life)
        cell.lifetimeRange = Float(particleLifespanVariance)
        cell.velocity = speed
        cell.velocityRange = speedVariance
        cell.emissionLongitude = CGFloat(angle * .pi / 180)
        cell.emissionRange = CGFloat(angleVariance * .pi / 180)
        cell.xAcceleration = gravityX
        // .pex files are authored y-up (yCoordFlipped == 1) — same as
        // macOS layer space; only unflipped files need the sign swap.
        cell.yAcceleration = yCoordFlipped == 1 ? gravityY : -gravityY

        let sizeScale = min(max(sizeScale, 0.5), 10)
        cell.scale = startParticleSize / textureSize * sizeScale
        cell.scaleRange = startParticleSizeVariance / textureSize * sizeScale
        cell.scaleSpeed = (finishParticleSize - startParticleSize) / life / textureSize * sizeScale

        cell.color = CGColor(
            red: startColor.red, green: startColor.green,
            blue: startColor.blue, alpha: startColor.alpha
        )
        cell.redRange = Float(startColorVariance.red)
        cell.greenRange = Float(startColorVariance.green)
        cell.blueRange = Float(startColorVariance.blue)
        cell.alphaRange = Float(startColorVariance.alpha)
        cell.redSpeed = Float((finishColor.red - startColor.red) / life)
        cell.greenSpeed = Float((finishColor.green - startColor.green) / life)
        cell.blueSpeed = Float((finishColor.blue - startColor.blue) / life)
        cell.alphaSpeed = Float((finishColor.alpha - startColor.alpha) / life)

        cell.spin = CGFloat((rotationEnd - rotationStart) * .pi / 180 / life)
        cell.spinRange = CGFloat((rotationStartVariance + rotationEndVariance) * .pi / 180 / life)

        let emitter = CAEmitterLayer()
        emitter.emitterCells = [cell]
        emitter.emitterShape = .point
        emitter.emitterMode = .points
        emitter.birthRate = 0   // off until a hand shows up
        // NOTE: isAdditive would want GL_ONE compositing; CAEmitterLayer has
        // no per-cell blend mode and layer compositing filters need
        // layerUsesCoreImageFilters on the whole window — plain alpha reads
        // fine for dust, so we deliberately skip it.
        return emitter
    }

    /// Soft radial sparkle used when a .pex has no texture (and as the
    /// built-in default emitter's texture).
    @MainActor
    public static let builtinSparkleTexture: CGImage = {
        let side = 64
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let gradient = NSGradient(colors: [
            NSColor(white: 1, alpha: 1),
            NSColor(white: 1, alpha: 0.55),
            NSColor(white: 1, alpha: 0),
        ], atLocations: [0, 0.35, 1], colorSpace: .deviceRGB)
        gradient?.draw(in: NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: side, height: side)), relativeCenterPosition: .zero)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }()

    /// The default "magic dust" when no .pex is chosen: dense, small, white
    /// sparkles with a gentle fall — tuned for hands.
    @MainActor
    public static func builtinSparkle() -> PEXEmitterConfig {
        var config = PEXEmitterConfig()
        config.maxParticles = 220
        config.particleLifeSpan = 1.1
        config.particleLifespanVariance = 0.4
        config.speed = 55
        config.speedVariance = 45
        config.angle = 90
        config.angleVariance = 360
        config.gravityY = -70
        config.startParticleSize = 10
        config.startParticleSizeVariance = 6
        config.finishParticleSize = 1
        config.startColor = PEXColor(red: 1, green: 0.98, blue: 0.85, alpha: 0.95)
        config.finishColor = PEXColor(red: 0.48, green: 0.62, blue: 0.71, alpha: 0)
        config.texture = builtinSparkleTexture
        return config
    }
}
