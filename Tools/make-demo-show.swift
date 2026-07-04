// Generates Demo.stagewizard at the repo root, exercising every cue type
// against the generated TestMedia. Compile together with the model sources:
//   swiftc -parse-as-library Sources/ShowModel/*.swift Tools/make-demo-show.swift -o /tmp/make-demo-show && /tmp/make-demo-show
import Foundation

@main
struct MakeDemoShow {
    static func main() throws {
        var show = ShowFile()
        show.settings.panicDuration = 3
        // Outputs are required: give the demo one group; assign your real
        // displays to it in Settings → Video Outputs.
        let mainOutput = OutputGroup(name: "Main")
        show.settings.outputGroups = [mainOutput]

        func media(_ file: String) -> MediaReference {
            MediaReference(relativePath: "TestMedia/\(file)", absolutePath: "TestMedia/\(file)")
        }

        var c1 = Cue(number: "1", name: "Intro tone (fade in, trimmed 1–6 s)",
                     body: .audio(AudioBody(media: media("tone-440-10s.wav"),
                                            startTime: 1, endTime: 6, volumeDB: -12,
                                            fadeInDuration: 1, fadeOutDuration: 1.5)))
        c1.follow = .autoContinue(postWait: 2)
        c1.notes = "Auto-continues to the video after 2 s."

        var c2 = Cue(number: "2", name: "Countdown video (hold last frame)",
                     body: .video(VideoBody(media: media("countdown-30s.mov"),
                                            startTime: 0, endTime: 8, volumeDB: -18,
                                            outputGroupID: mainOutput.id,
                                            endBehavior: .holdLastFrame,
                                            fadeInDuration: 0.5, fadeOutDuration: 1)))
        c2.follow = .autoFollow
        c2.notes = "Holds its last frame when it reaches 8 s; auto-follow fires cue 3."

        let c3 = Cue(number: "3", name: "Count beeps (loop ×2)",
                     body: .audio(AudioBody(media: media("count-60s.wav"),
                                            startTime: 0, endTime: 4, playCount: 2, volumeDB: -15)))

        let group = Cue(number: "10", name: "Timeline: tone + ident video",
                        body: .group(GroupBody(mode: .timeline)))

        var g1 = Cue(number: "10.1", name: "Tone bed",
                     body: .audio(AudioBody(media: media("tone-440-10s.wav"),
                                            startTime: 0, endTime: 5, volumeDB: -20,
                                            fadeInDuration: 0.5, fadeOutDuration: 0.5)))
        g1.parentID = group.id
        var g2 = Cue(number: "10.2", name: "Ident video (starts at +1.5 s)",
                     body: .video(VideoBody(media: media("ident-5s.mov"),
                                            volumeDB: -20, outputGroupID: mainOutput.id, endBehavior: .stopAndUnload,
                                            fadeInDuration: 0.5, fadeOutDuration: 0.5)))
        g2.parentID = group.id
        var groupBody = GroupBody(mode: .timeline)
        groupBody.childOffsets = [g2.id: 1.5]
        var groupCue = group
        groupCue.body = .group(groupBody)

        let fade = Cue(number: "20", name: "Fade out the video",
                       body: .fade(FadeBody(targetID: c2.id, duration: 3, curve: .dbLinear,
                                            toVolumeDB: silenceFloorDB, toOpacity: 0,
                                            stopTargetWhenDone: true)))

        let stopAll = Cue(number: "99", name: "Stop everything (3 s fade)",
                          body: .stop(StopBody(targetID: nil, fadeOutTime: 3)))

        show.cues = [c1, c2, c3, groupCue, g1, g2, fade, stopAll]

        let data = try show.encoded()
        let url = URL(fileURLWithPath: "Demo.stagewizard")
        try data.write(to: url)
        print("Wrote \(url.path) with \(show.cues.count) cues")
    }
}
