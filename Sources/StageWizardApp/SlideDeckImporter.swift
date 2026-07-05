import AppKit
import PDFKit
import UniformTypeIdentifiers
import CryptoKit

/// Turns a presentation deck (.pptx/.ppt/.pdf) into a sequence of slide cues.
/// Decks are flattened to per-slide PNGs at import time by the best available
/// converter — nothing external ever runs at showtime:
///
///   1. ONLYOFFICE x2t (OOXML-native, best fidelity, ~1 s)
///   2. Microsoft PowerPoint via AppleScript export → PDF → PDFKit
///   3. Apple Keynote via AppleScript export → PDF → PDFKit
///   4. LibreOffice headless → PDF → PDFKit
///   5. PDF input renders directly via PDFKit (no external dependency)
///
/// StageWizard bundles NOTHING — it probes for user-installed converters.
@MainActor
enum SlideDeckImporter {
    static let deckExtensions: Set<String> = ["pptx", "ppt", "pdf"]

    static func isDeck(_ url: URL) -> Bool {
        deckExtensions.contains(url.pathExtension.lowercased())
    }

    enum ImportError: LocalizedError {
        case noConverter
        case conversionFailed(String)
        case emptyDeck

        var errorDescription: String? {
            switch self {
            case .noConverter:
                return "No PowerPoint converter found. Install ONLYOFFICE, PowerPoint, Keynote, or LibreOffice — or export the deck to PDF and drop that instead."
            case .conversionFailed(let why):
                return "Deck conversion failed: \(why)"
            case .emptyDeck:
                return "The deck produced no slides."
            }
        }
    }

    // MARK: - Entry points

    /// Menu-driven import with a file picker.
    static func importDeckViaPanel(into document: ShowDocumentController, app: AppModel) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf, UTType("org.openxmlformats.presentationml.presentation"), UTType("com.microsoft.powerpoint.ppt")].compactMap { $0 }
        panel.message = "Choose a presentation (.pptx, .ppt, or .pdf)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importDeck(url: url, at: nil, into: document, app: app)
    }

    /// Drag & drop / shared entry: converts async, then inserts slide cues.
    static func importDeck(url: URL, at insertIndex: Int?, into document: ShowDocumentController, app: AppModel) {
        app.pushWarning("Converting “\(url.lastPathComponent)” to slides…")
        let renderSize = targetRenderSize(document: document)
        Task {
            do {
                let result = try await convert(deckURL: url, renderSize: renderSize)
                insertSlideCues(
                    images: result.imageURLs, deckURL: url,
                    at: insertIndex, into: document, app: app
                )
                app.pushWarning("Imported \(result.imageURLs.count) slides via \(result.converter).")
            } catch {
                app.pushWarning(error.localizedDescription)
            }
        }
    }

    /// Re-run conversion for an existing slide cue's source deck and update
    /// every sibling cue that came from the same deck.
    static func reconvert(cueID: UUID, document: ShowDocumentController, app: AppModel) {
        guard let cue = document.cue(withID: cueID),
              case .slide(let body) = cue.body,
              let sourceURL = body.sourceDeck?.resolve(showFolder: document.showFolder) else {
            app.pushWarning("Source deck not found — relink or re-import it.")
            return
        }
        app.pushWarning("Reconverting “\(sourceURL.lastPathComponent)”…")
        let renderSize = targetRenderSize(document: document)
        Task {
            do {
                // Bust the cache: reconvert is explicitly "render again".
                let result = try await convert(deckURL: sourceURL, renderSize: renderSize, ignoreCache: true)
                document.mutate { show in
                    for index in show.cues.indices {
                        guard case .slide(var slide) = show.cues[index].body,
                              slide.sourceDeck?.absolutePath == body.sourceDeck?.absolutePath,
                              let slideIndex = slide.slideIndex,
                              slideIndex - 1 < result.imageURLs.count else { continue }
                        slide.media = MediaReference(fileURL: result.imageURLs[slideIndex - 1], showFolder: document.showFolder)
                        slide.slideCount = result.imageURLs.count
                        show.cues[index].body = .slide(slide)
                    }
                }
                app.pushWarning("Reconverted \(result.imageURLs.count) slides via \(result.converter).")
            } catch {
                app.pushWarning(error.localizedDescription)
            }
        }
    }

    // MARK: - Cue construction

    private static func insertSlideCues(
        images: [URL], deckURL: URL,
        at insertIndex: Int?, into document: ShowDocumentController, app: AppModel
    ) {
        guard !images.isEmpty else { return }
        let sourceRef = MediaReference(fileURL: deckURL, showFolder: document.showFolder)
        let outputGroup = CueFactory.defaultOutputGroupID(in: document)

        var newCues: [Cue] = []
        for (index, imageURL) in images.enumerated() {
            let body = SlideBody(
                media: MediaReference(fileURL: imageURL, showFolder: document.showFolder),
                sourceDeck: sourceRef,
                slideIndex: index + 1,
                slideCount: images.count,
                outputGroupID: outputGroup
            )
            newCues.append(Cue(number: "", body: .slide(body)))
        }
        // Trailing stop so the deck can end cleanly on the last GO.
        let stop = Cue(
            number: "",
            name: "Clear “\((deckURL.lastPathComponent as NSString).deletingPathExtension)”",
            body: .stop(StopBody(targetID: newCues.last?.id, fadeOutTime: 0.3))
        )
        newCues.append(stop)

        document.mutate { show in
            var index = insertIndex.map { min($0, show.cues.count) } ?? show.cues.count
            for var cue in newCues {
                cue.number = show.nextCueNumber()
                show.cues.insert(cue, at: index)
                index += 1
            }
        }
        document.selection = [newCues[0].id]
    }

    /// Largest pixel size among the default output group's displays.
    private static func targetRenderSize(document: ShowDocumentController) -> CGSize {
        var best = CGSize(width: 1920, height: 1080)
        if let groupID = CueFactory.defaultOutputGroupID(in: document),
           let group = document.show.settings.group(withID: groupID) {
            for fingerprint in group.displays {
                if CGFloat(fingerprint.pixelWidth) > best.width {
                    best = CGSize(width: fingerprint.pixelWidth, height: fingerprint.pixelHeight)
                }
            }
        }
        return best
    }

    // MARK: - Conversion pipeline

    struct ConversionResult: Sendable {
        let imageURLs: [URL]
        let converter: String
    }

    nonisolated static func convert(deckURL: URL, renderSize: CGSize, ignoreCache: Bool = false) async throws -> ConversionResult {
        let cacheDir = try cacheDirectory(for: deckURL, renderSize: renderSize)
        if !ignoreCache {
            let cached = slideImages(in: cacheDir)
            if !cached.isEmpty {
                return ConversionResult(imageURLs: cached, converter: "cache")
            }
        }
        try? FileManager.default.removeItem(at: cacheDir)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        if deckURL.pathExtension.lowercased() == "pdf" {
            let images = try await renderPDF(url: deckURL, into: cacheDir, renderSize: renderSize)
            return ConversionResult(imageURLs: images, converter: "PDFKit")
        }

        // Tier 1: ONLYOFFICE x2t → per-slide PNGs directly.
        if let x2t = X2TConverter.probe() {
            do {
                let images = try await X2TConverter.convert(x2t: x2t, deckURL: deckURL, into: cacheDir, renderSize: renderSize)
                if !images.isEmpty { return ConversionResult(imageURLs: images, converter: "ONLYOFFICE") }
            } catch {
                NSLog("x2t failed, trying next tier: \(error)")
            }
        }
        // Tiers 2+3: PowerPoint / Keynote AppleScript export to PDF.
        for app in [ScriptableConverter.powerPoint, ScriptableConverter.keynote] where app.isInstalled {
            do {
                let pdf = try await app.exportPDF(deckURL: deckURL, into: cacheDir)
                let images = try await renderPDF(url: pdf, into: cacheDir, renderSize: renderSize)
                if !images.isEmpty { return ConversionResult(imageURLs: images, converter: app.displayName) }
            } catch {
                NSLog("\(app.displayName) export failed, trying next tier: \(error)")
            }
        }
        // Tier 4: LibreOffice headless.
        if let soffice = LibreOfficeConverter.probe() {
            do {
                let pdf = try await LibreOfficeConverter.convertToPDF(soffice: soffice, deckURL: deckURL, into: cacheDir)
                let images = try await renderPDF(url: pdf, into: cacheDir, renderSize: renderSize)
                if !images.isEmpty { return ConversionResult(imageURLs: images, converter: "LibreOffice") }
            } catch {
                NSLog("LibreOffice failed: \(error)")
            }
        }
        throw ImportError.noConverter
    }

    nonisolated static func cacheDirectory(for deckURL: URL, renderSize: CGSize) throws -> URL {
        let attributes = try? FileManager.default.attributesOfItem(atPath: deckURL.path)
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(deckURL.path)|\(mtime)|\(Int(renderSize.width))x\(Int(renderSize.height))"
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StageWizard/SlideCache", isDirectory: true)
        let name = (deckURL.lastPathComponent as NSString).deletingPathExtension
        return base.appendingPathComponent("\(name)-\(digest)", isDirectory: true)
    }

    nonisolated static func slideImages(in dir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { a, b in
                a.lastPathComponent.compare(b.lastPathComponent, options: .numeric) == .orderedAscending
            }
    }

    /// PDF → per-page PNGs via PDFKit (system framework — the zero-dependency floor).
    nonisolated static func renderPDF(url: URL, into dir: URL, renderSize: CGSize) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else {
                throw ImportError.conversionFailed("unreadable PDF")
            }
            var urls: [URL] = []
            for pageIndex in 0..<pdf.pageCount {
                guard let page = pdf.page(at: pageIndex) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let scale = min(renderSize.width / bounds.width, renderSize.height / bounds.height)
                let pixelWidth = Int(bounds.width * scale)
                let pixelHeight = Int(bounds.height * scale)
                guard let context = CGContext(
                    data: nil, width: pixelWidth, height: pixelHeight,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { continue }
                context.setFillColor(.white)
                context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -bounds.minX, y: -bounds.minY)
                page.draw(with: .mediaBox, to: context)
                guard let image = context.makeImage() else { continue }
                let out = dir.appendingPathComponent(String(format: "slide-%03d.png", pageIndex + 1))
                guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
                urls.append(out)
            }
            guard !urls.isEmpty else { throw ImportError.emptyDeck }
            return urls
        }.value
    }
}

// MARK: - Tier 1: ONLYOFFICE x2t

enum X2TConverter {
    struct Paths: Sendable {
        let binary: URL
        let allFonts: URL
        let fontDir: URL
    }

    /// Both the binary AND the app-generated font cache must exist — without
    /// the font index x2t renders garbled glyphs (verified in research).
    static func probe() -> Paths? {
        let binary = URL(fileURLWithPath: "/Applications/ONLYOFFICE.app/Contents/Resources/converter/x2t")
        let fontDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("asc.onlyoffice.ONLYOFFICE/data/fonts")
        let allFonts = fontDir.appendingPathComponent("AllFonts.js")
        guard FileManager.default.isExecutableFile(atPath: binary.path),
              FileManager.default.fileExists(atPath: allFonts.path) else { return nil }
        return Paths(binary: binary, allFonts: allFonts, fontDir: fontDir)
    }

    /// Template verified working in research (topng2.xml): PNG format 1029,
    /// thumbnail block with first=false → image1.png … imageN.png.
    static func paramsXML(paths: Paths, deckURL: URL, outputPNG: URL, renderSize: CGSize) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <TaskQueueDataConvert xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <m_sFileFrom>\(deckURL.path)</m_sFileFrom>
          <m_sFileTo>\(outputPNG.path)</m_sFileTo>
          <m_nFormatTo>1029</m_nFormatTo>
          <m_sAllFontsPath>\(paths.allFonts.path)</m_sAllFontsPath>
          <m_sFontDir>\(paths.fontDir.path)</m_sFontDir>
          <m_oThumbnail>
            <format>4</format>
            <aspect>1</aspect>
            <first>false</first>
            <width>\(Int(renderSize.width))</width>
            <height>\(Int(renderSize.height))</height>
            <zip>false</zip>
          </m_oThumbnail>
        </TaskQueueDataConvert>
        """
    }

    static func convert(x2t paths: Paths, deckURL: URL, into dir: URL, renderSize: CGSize) async throws -> [URL] {
        let outputPNG = dir.appendingPathComponent("slide.png")
        let params = paramsXML(paths: paths, deckURL: deckURL, outputPNG: outputPNG, renderSize: renderSize)
        let paramsURL = dir.appendingPathComponent("params.xml")
        try params.write(to: paramsURL, atomically: true, encoding: .utf8)
        try await runProcess(paths.binary.path, [paramsURL.path])
        try? FileManager.default.removeItem(at: paramsURL)

        // x2t emits image1.png…imageN.png into a folder named after m_sFileTo.
        let emitted = dir.appendingPathComponent("slide.png", isDirectory: true)
        var images = SlideDeckImporter.slideImages(in: emitted)
        if images.isEmpty {
            images = SlideDeckImporter.slideImages(in: dir)
        }
        // Normalize names to slide-NNN.png in the cache root.
        var normalized: [URL] = []
        for (index, url) in images.enumerated() {
            let out = dir.appendingPathComponent(String(format: "slide-%03d.png", index + 1))
            if url != out {
                try? FileManager.default.removeItem(at: out)
                try FileManager.default.moveItem(at: url, to: out)
            }
            normalized.append(out)
        }
        try? FileManager.default.removeItem(at: emitted)
        return normalized
    }
}

// MARK: - Tiers 2+3: PowerPoint / Keynote via osascript

enum ScriptableConverter: Sendable {
    case powerPoint
    case keynote

    var displayName: String {
        switch self {
        case .powerPoint: return "PowerPoint"
        case .keynote: return "Keynote"
        }
    }

    var isInstalled: Bool {
        let path = switch self {
        case .powerPoint: "/Applications/Microsoft PowerPoint.app"
        case .keynote: "/Applications/Keynote.app"
        }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Export the deck to PDF by scripting the app (Automation/TCC consent is
    /// requested the first time — always at import, never during a show).
    func exportPDF(deckURL: URL, into dir: URL) async throws -> URL {
        let pdfURL = dir.appendingPathComponent("export.pdf")
        try? FileManager.default.removeItem(at: pdfURL)
        let script = switch self {
        case .powerPoint: """
            tell application "Microsoft PowerPoint"
                open (POSIX file "\(deckURL.path)")
                set thePres to active presentation
                save thePres in (POSIX file "\(pdfURL.path)") as save as PDF
                close thePres saving no
            end tell
            """
        case .keynote: """
            tell application "Keynote"
                set theDoc to open (POSIX file "\(deckURL.path)")
                export theDoc to (POSIX file "\(pdfURL.path)") as PDF
                close theDoc without saving
            end tell
            """
        }
        try await runProcess("/usr/bin/osascript", ["-e", script])
        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            throw SlideDeckImporter.ImportError.conversionFailed("\(displayName) produced no PDF")
        }
        return pdfURL
    }
}

// MARK: - Tier 4: LibreOffice headless

enum LibreOfficeConverter {
    static func probe() -> URL? {
        let url = URL(fileURLWithPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func convertToPDF(soffice: URL, deckURL: URL, into dir: URL) async throws -> URL {
        // Private profile: without it a user's open LibreOffice GUI silently
        // swallows the conversion via the single-instance lock.
        let profile = dir.appendingPathComponent("lo-profile", isDirectory: true)
        try await runProcess(soffice.path, [
            "--headless", "--norestore", "--nolockcheck",
            "-env:UserInstallation=file://\(profile.path)",
            "--convert-to", "pdf", "--outdir", dir.path, deckURL.path,
        ])
        try? FileManager.default.removeItem(at: profile)
        let name = (deckURL.lastPathComponent as NSString).deletingPathExtension
        let pdf = dir.appendingPathComponent("\(name).pdf")
        guard FileManager.default.fileExists(atPath: pdf.path) else {
            throw SlideDeckImporter.ImportError.conversionFailed("LibreOffice produced no PDF")
        }
        return pdf
    }
}

// MARK: - Shared process runner

/// Run a converter process off the main actor with a hard timeout.
func runProcess(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 120) async throws {
    try await Task.detached(priority: .userInitiated) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            process.terminate()
            throw SlideDeckImporter.ImportError.conversionFailed("\((launchPath as NSString).lastPathComponent) timed out")
        }
        if process.terminationStatus != 0 {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SlideDeckImporter.ImportError.conversionFailed(
                "\((launchPath as NSString).lastPathComponent) exited \(process.terminationStatus): \(stderr.prefix(200))"
            )
        }
    }.value
}
