#!/usr/bin/env swift
// Generates deterministic test media for StageWizard development:
//   tone-440-10s.wav    steady stereo tone (L slightly detuned from R)
//   count-60s.wav       100 ms beep at every second (higher pitch each 10 s)
//                       — lets you HEAR whether trim in/out points are exact
//   countdown-30s.mov   720p H.264, on-screen seconds counter + moving bar,
//                       beep audio track (verifies AV sync + audio routing)
//   ident-5s.mov        short blue clip, same structure
//
// Usage: swift Tools/make-test-media.swift [outputDir=TestMedia]

import AVFoundation
import AppKit

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "TestMedia")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let sampleRate = 48_000.0

// MARK: - Audio synthesis

func writeWAV(to url: URL, seconds: Double, render: (Int, Int) -> (Float, Float)) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let total = Int(seconds * sampleRate)
    let chunk = 48_000
    var written = 0
    while written < total {
        let n = min(chunk, total - written)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        for i in 0..<n {
            let (l, r) = render(written + i, total)
            left[i] = l
            right[i] = r
        }
        try file.write(from: buffer)
        written += n
    }
}

func tone(_ freq: Double, _ sample: Int, amp: Float = 0.5) -> Float {
    amp * Float(sin(2 * .pi * freq * Double(sample) / sampleRate))
}

/// 100 ms beep starting exactly at each whole second; 1320 Hz on 10 s marks,
/// 880 Hz otherwise. 5 ms edge ramps to avoid clicks in the asset itself.
func beepSample(_ sample: Int) -> Float {
    let inSecond = sample % Int(sampleRate)
    let beepLen = Int(sampleRate * 0.1)
    guard inSecond < beepLen else { return 0 }
    let second = sample / Int(sampleRate)
    let freq = second % 10 == 0 ? 1320.0 : 880.0
    let ramp = Int(sampleRate * 0.005)
    let env: Float =
        inSecond < ramp ? Float(inSecond) / Float(ramp)
        : inSecond > beepLen - ramp ? Float(beepLen - inSecond) / Float(ramp)
        : 1
    return env * tone(freq, sample, amp: 0.6)
}

// MARK: - Video synthesis

func writeVideo(to url: URL, seconds: Int, hue: CGFloat, label: String) throws {
    let size = CGSize(width: 1280, height: 720)
    let fps = 30
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    )
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    for frame in 0..<(seconds * fps) {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
        guard let pb = pixelBuffer else { fatalError("no pixel buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx

        let second = frame / fps
        let subFrame = frame % fps
        NSColor(hue: hue, saturation: 0.7, brightness: second % 2 == 0 ? 0.35 : 0.25, alpha: 1).setFill()
        ctx.fill(CGRect(origin: .zero, size: size))

        // Moving bar: sweeps once per second — freezes visibly on hold-last-frame.
        NSColor.white.withAlphaComponent(0.9).setFill()
        let barX = size.width * CGFloat(subFrame) / CGFloat(fps)
        ctx.fill(CGRect(x: barX - 3, y: 0, width: 6, height: size.height))

        let text = "\(label)  \(String(format: "%02d:%02d", second / 60, second % 60))  f\(subFrame)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 90, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let bounds = str.size()
        str.draw(at: NSPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))

        NSGraphicsContext.current = nil
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { fatalError("video write failed: \(String(describing: writer.error))") }
}

/// Mux a video-only .mov with a WAV into one .mov (audio transcoded to AAC).
func mux(video: URL, audio: URL, to url: URL) throws {
    let composition = AVMutableComposition()
    let videoAsset = AVURLAsset(url: video)
    let audioAsset = AVURLAsset(url: audio)
    let sem = DispatchSemaphore(value: 0)
    var failure: String?
    Task {
        do {
            let vTrack = try await videoAsset.loadTracks(withMediaType: .video)[0]
            let aTrack = try await audioAsset.loadTracks(withMediaType: .audio)[0]
            let duration = try await videoAsset.load(.duration)
            let vComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            let aComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try vComp.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: vTrack, at: .zero)
            try aComp.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: aTrack, at: .zero)
            let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
            try? FileManager.default.removeItem(at: url)
            try await export.export(to: url, as: .mov)
        } catch {
            failure = "\(error)"
        }
        sem.signal()
    }
    sem.wait()
    if let failure { fatalError("mux failed: \(failure)") }
}

// MARK: - Generate

print("Generating test media in \(outputDir.path)…")

try writeWAV(to: outputDir.appendingPathComponent("tone-440-10s.wav"), seconds: 10) { i, total in
    let fade = min(1, Float(total - i) / Float(sampleRate * 0.05), Float(i) / Float(sampleRate * 0.05))
    return (fade * tone(440, i, amp: 0.4), fade * tone(442, i, amp: 0.4))
}
print("  tone-440-10s.wav")

try writeWAV(to: outputDir.appendingPathComponent("count-60s.wav"), seconds: 60) { i, _ in
    let s = beepSample(i)
    return (s, s)
}
print("  count-60s.wav")

let tmpVideo = outputDir.appendingPathComponent("_tmp-video.mov")
let tmpBeeps = outputDir.appendingPathComponent("_tmp-beeps.wav")

try writeWAV(to: tmpBeeps, seconds: 30) { i, _ in (beepSample(i), beepSample(i)) }
try writeVideo(to: tmpVideo, seconds: 30, hue: 0.08, label: "COUNT")
try mux(video: tmpVideo, audio: tmpBeeps, to: outputDir.appendingPathComponent("countdown-30s.mov"))
print("  countdown-30s.mov")

try writeWAV(to: tmpBeeps, seconds: 5) { i, _ in (beepSample(i), beepSample(i)) }
try writeVideo(to: tmpVideo, seconds: 5, hue: 0.6, label: "IDENT")
try mux(video: tmpVideo, audio: tmpBeeps, to: outputDir.appendingPathComponent("ident-5s.mov"))
print("  ident-5s.mov")

try? FileManager.default.removeItem(at: tmpVideo)
try? FileManager.default.removeItem(at: tmpBeeps)
print("Done.")
