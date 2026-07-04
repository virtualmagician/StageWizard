import SwiftUI
import AVFoundation

// MARK: - Waveform data

/// Downsampled min/max peaks for drawing. Loaded once per file, off-main.
struct WaveformData: Sendable {
    var mins: [Float]
    var maxs: [Float]
    var duration: TimeInterval

    static func load(url: URL, buckets: Int = 800) async throws -> WaveformData {
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: url)
            let totalFrames = Int(file.length)
            let sampleRate = file.processingFormat.sampleRate
            guard totalFrames > 0 else {
                return WaveformData(mins: [], maxs: [], duration: 0)
            }
            let framesPerBucket = max(1, totalFrames / buckets)
            var mins = [Float](repeating: 0, count: buckets)
            var maxs = [Float](repeating: 0, count: buckets)

            let chunkFrames = 1 << 17
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(chunkFrames)
            )!
            var frameIndex = 0
            while frameIndex < totalFrames {
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                let channels = Int(file.processingFormat.channelCount)
                let n = Int(buffer.frameLength)
                if let data = buffer.floatChannelData {
                    for i in 0..<n {
                        var lo: Float = 0, hi: Float = 0
                        for c in 0..<channels {
                            let v = data[c][i]
                            lo = min(lo, v)
                            hi = max(hi, v)
                        }
                        let bucket = min((frameIndex + i) / framesPerBucket, buckets - 1)
                        mins[bucket] = min(mins[bucket], lo)
                        maxs[bucket] = max(maxs[bucket], hi)
                    }
                }
                frameIndex += n
            }
            return WaveformData(mins: mins, maxs: maxs, duration: Double(totalFrames) / sampleRate)
        }.value
    }
}

// MARK: - Audio trim editor

/// Waveform with draggable IN/OUT markers. Regions outside the trim are dimmed.
struct WaveformTrimEditor: View {
    let fileURL: URL
    @Binding var startTime: TimeInterval
    @Binding var endTime: TimeInterval?

    @State private var waveform: WaveformData?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let waveform, waveform.duration > 0 {
                TrimTimeline(duration: waveform.duration, startTime: $startTime, endTime: $endTime) { size in
                    WaveformShape(data: waveform)
                        .fill(.tint.opacity(0.85))
                        .frame(width: size.width, height: size.height)
                }
            } else if loadFailed {
                Text("Couldn't read audio for waveform display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
        }
        .task(id: fileURL) {
            waveform = nil
            loadFailed = false
            do {
                waveform = try await WaveformData.load(url: fileURL)
            } catch {
                loadFailed = true
            }
        }
    }
}

struct WaveformShape: Shape {
    let data: WaveformData

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = data.maxs.count
        guard count > 0 else { return path }
        let mid = rect.midY
        let halfH = rect.height / 2
        let step = rect.width / CGFloat(count)
        for i in 0..<count {
            let x = rect.minX + CGFloat(i) * step
            let top = mid - CGFloat(data.maxs[i]) * halfH
            let bottom = mid - CGFloat(data.mins[i]) * halfH
            path.addRect(CGRect(x: x, y: top, width: max(step * 0.8, 0.5), height: max(bottom - top, 1)))
        }
        return path
    }
}

// MARK: - Shared trim timeline (markers + dimming + time ruler)

/// Generic trim surface: draws `content`, dims outside the in/out range, and
/// provides draggable IN/OUT handles. Used by both audio and video editors.
struct TrimTimeline<Content: View>: View {
    let duration: TimeInterval
    @Binding var startTime: TimeInterval
    @Binding var endTime: TimeInterval?
    @ViewBuilder var content: (CGSize) -> Content

    private var effectiveEnd: TimeInterval { endTime ?? duration }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    content(geo.size)

                    // Dim outside the trim.
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .frame(width: x(for: startTime, width: width))
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .frame(width: max(0, width - x(for: effectiveEnd, width: width)))
                        .offset(x: x(for: effectiveEnd, width: width))

                    marker(color: .green)
                        .position(x: x(for: startTime, width: width), y: geo.size.height / 2)
                        .gesture(dragGesture(width: width) { t in
                            startTime = min(max(0, t), effectiveEnd - 0.01)
                        })
                        .help("IN point — drag")
                    marker(color: .red)
                        .position(x: x(for: effectiveEnd, width: width), y: geo.size.height / 2)
                        .gesture(dragGesture(width: width) { t in
                            let clamped = max(startTime + 0.01, min(t, duration))
                            endTime = clamped >= duration - 0.01 ? nil : clamped
                        })
                        .help("OUT point — drag (snap to far right for file end)")
                }
            }
            .frame(height: 72)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Text("IN " + Timecode.format(startTime))
                    .foregroundStyle(.green)
                Spacer()
                Text(Timecode.format(duration))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("OUT " + (endTime.map { Timecode.format($0) } ?? "file end"))
                    .foregroundStyle(.red)
            }
            .font(.caption2.monospacedDigit())
        }
    }

    private func x(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    private func dragGesture(width: CGFloat, update: @escaping (TimeInterval) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard width > 0 else { return }
                update(TimeInterval(value.location.x / width) * duration)
            }
    }

    private func marker(color: Color) -> some View {
        ZStack {
            Rectangle()
                .fill(color)
                .frame(width: 2)
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
        }
        .frame(width: 16, height: 72)   // generous hit target
        .contentShape(Rectangle())
    }
}

// MARK: - Video trim editor

/// Owns a non-Sendable AVAssetImageGenerator behind an actor so thumbnail
/// requests from SwiftUI tasks don't send it across isolation domains.
actor ThumbnailEngine {
    // Confinement invariant: only touched inside this actor's methods.
    private nonisolated(unsafe) let generator: AVAssetImageGenerator
    let duration: TimeInterval

    init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 135)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        self.generator = generator
    }

    func image(at seconds: TimeInterval) async throws -> CGImage {
        try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}

/// Thumbnail filmstrip with the same draggable trim markers, plus a scrub
/// preview image at the hovered/dragged time.
struct VideoTrimEditor: View {
    let fileURL: URL
    @Binding var startTime: TimeInterval
    @Binding var endTime: TimeInterval?

    @State private var thumbnails: [CGImage] = []
    @State private var duration: TimeInterval = 0
    @State private var scrubImage: CGImage?
    @State private var scrubTime: TimeInterval?
    @State private var engine: ThumbnailEngine?

    var body: some View {
        VStack(spacing: 6) {
            if duration > 0 {
                TrimTimeline(duration: duration, startTime: $startTime, endTime: $endTime) { size in
                    filmstrip(size: size)
                }
                .overlay(alignment: .top) {
                    if let scrubImage, scrubTime != nil {
                        Image(decorative: scrubImage, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .shadow(radius: 4)
                            .offset(y: -98)
                    }
                }
                scrubBar
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
        }
        .task(id: fileURL) {
            await loadFilmstrip()
        }
    }

    private func filmstrip(size: CGSize) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width / CGFloat(max(thumbnails.count, 1)), height: size.height)
                    .clipped()
            }
        }
    }

    /// Scrub slider under the strip: preview any frame, set IN/OUT at playhead.
    private var scrubBar: some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { scrubTime ?? startTime },
                    set: { t in
                        scrubTime = t
                        requestScrubImage(at: t)
                    }
                ),
                in: 0...max(duration, 0.01)
            )
            Text(Timecode.format(scrubTime ?? startTime))
                .font(.caption.monospacedDigit())
                .frame(width: 60, alignment: .trailing)
            Button("Set IN") {
                if let t = scrubTime { startTime = min(t, (endTime ?? duration) - 0.01) }
            }
            .controlSize(.small)
            Button("Set OUT") {
                if let t = scrubTime, t > startTime {
                    endTime = t >= duration - 0.01 ? nil : t
                }
            }
            .controlSize(.small)
        }
    }

    private func loadFilmstrip() async {
        thumbnails = []
        duration = 0
        guard let engine = try? await ThumbnailEngine(url: fileURL) else { return }
        self.engine = engine
        duration = engine.duration

        let count = 10
        var images: [CGImage] = []
        for i in 0..<count {
            let t = duration * (Double(i) + 0.5) / Double(count)
            if let image = try? await engine.image(at: t) {
                images.append(image)
            }
        }
        thumbnails = images
    }

    private func requestScrubImage(at time: TimeInterval) {
        guard let engine else { return }
        Task {
            if let image = try? await engine.image(at: time) {
                // Only apply if the user hasn't scrubbed far past this request.
                if let current = scrubTime, abs(current - time) < 0.5 {
                    scrubImage = image
                }
            }
        }
    }
}
