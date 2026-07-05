import AppKit

// Generates the .stagewizard Finder document icon: the app icon artwork
// composited on a classic folded-corner page, exported at every size
// LaunchServices asks for and packed into an .icns with iconutil.
//
//   swift Tools/make-doc-icon.swift Support/AppIcon.png Support/DocIcon.icns

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-doc-icon.swift <appicon.png> <out.icns>\n".utf8))
    exit(1)
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
guard let appIcon = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write(Data("cannot read \(arguments[1])\n".utf8))
    exit(1)
}

func renderDocIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(pixels)
    let pageWidth = s * 0.70
    let pageHeight = s * 0.92
    let pageX = (s - pageWidth) / 2
    let pageY = (s - pageHeight) / 2
    let fold = pageWidth * 0.26

    let page = NSBezierPath()
    page.move(to: NSPoint(x: pageX, y: pageY))
    page.line(to: NSPoint(x: pageX + pageWidth, y: pageY))
    page.line(to: NSPoint(x: pageX + pageWidth, y: pageY + pageHeight - fold))
    page.line(to: NSPoint(x: pageX + pageWidth - fold, y: pageY + pageHeight))
    page.line(to: NSPoint(x: pageX, y: pageY + pageHeight))
    page.close()
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    page.fill()
    NSColor(calibratedWhite: 0.72, alpha: 1).setStroke()
    page.lineWidth = max(1, s * 0.006)
    page.stroke()

    let foldPath = NSBezierPath()
    foldPath.move(to: NSPoint(x: pageX + pageWidth - fold, y: pageY + pageHeight))
    foldPath.line(to: NSPoint(x: pageX + pageWidth - fold, y: pageY + pageHeight - fold))
    foldPath.line(to: NSPoint(x: pageX + pageWidth, y: pageY + pageHeight - fold))
    foldPath.close()
    NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
    foldPath.fill()
    foldPath.stroke()

    // App artwork centered, nudged below the fold.
    let iconSide = pageWidth * 0.74
    let iconRect = NSRect(
        x: pageX + (pageWidth - iconSide) / 2,
        y: pageY + (pageHeight - iconSide) / 2 - pageHeight * 0.05,
        width: iconSide, height: iconSide
    )
    appIcon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
    return rep
}

let iconsetURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("DocIcon-\(ProcessInfo.processInfo.globallyUniqueString).iconset")
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconsetURL) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = renderDocIcon(pixels: points * scale)
        let suffix = scale == 2 ? "@2x" : ""
        let fileURL = iconsetURL.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try rep.representation(using: .png, properties: [:])!.write(to: fileURL)
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(outputURL.path)")
