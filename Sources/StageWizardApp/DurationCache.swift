import AVFoundation
import Observation

/// Async media-duration lookup for the cue list's Duration column.
/// First read returns nil and kicks off a load; the @Observable mutation
/// refreshes the rows when the value lands.
@MainActor
@Observable
final class DurationCache {
    static let shared = DurationCache()

    private var durations: [String: TimeInterval] = [:]
    private var pending: Set<String> = []

    func duration(for url: URL) -> TimeInterval? {
        let key = url.path
        if let cached = durations[key] { return cached }
        if !pending.contains(key) {
            pending.insert(key)
            Task {
                let asset = AVURLAsset(url: url)
                let seconds = (try? await asset.load(.duration))?.seconds
                durations[key] = seconds?.isFinite == true ? seconds! : 0
                pending.remove(key)
            }
        }
        return nil
    }

    /// Effective single-pass duration of a cue as shown in the list.
    /// nil = unknown yet (loading) or not applicable.
    func effectiveDuration(of cue: Cue, in show: ShowFile, showFolder: URL?) -> TimeInterval? {
        switch cue.body {
        case .audio(let body):
            return trimmed(media: body.media, start: body.startTime, end: body.endTime, showFolder: showFolder)
        case .video(let body):
            return trimmed(media: body.media, start: body.startTime, end: body.endTime, showFolder: showFolder)
        case .fade(let body):
            return body.duration
        case .stop(let body):
            return body.fadeOutTime
        case .camera, .slide, .broken:
            return nil
        case .group(let body) where body.mode == .enterAndPlayFirst:
            return nil   // GO-driven container — no fixed duration
        case .group(let body):
            let children = show.children(of: cue.id)
            guard !children.isEmpty else { return 0 }
            var longest: TimeInterval = 0
            for child in children {
                guard let childDuration = effectiveDuration(of: child, in: show, showFolder: showFolder) else {
                    return nil   // still loading — show "—" rather than a wrong number
                }
                longest = max(longest, body.offset(for: child.id) + child.preWait + childDuration)
            }
            return longest
        }
    }

    private func trimmed(media: MediaReference, start: TimeInterval, end: TimeInterval?, showFolder: URL?) -> TimeInterval? {
        if let end { return max(0, end - start) }
        guard let url = media.resolve(showFolder: showFolder),
              let full = duration(for: url) else { return nil }
        return max(0, full - start)
    }
}
