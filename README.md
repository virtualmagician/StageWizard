# StageWizard

Native macOS show control for live performance: a cue-based audio, video, and
camera playback engine built for running real stages — theaters, magic shows,
talks, and touring rigs. Apple Silicon, macOS 26.1+, Swift 6 (strict
concurrency), SwiftUI + AppKit, AVFoundation. No third-party dependencies.

## What it does

- **Audio cues** — per-cue output-device routing (Core Audio, hot-plug aware),
  sample-accurate in/out trim, per-cue volume in dB, fade in/out, gapless
  looping with play counts or infinite loop, exit-loop.
- **Video cues** — playback on virtual **output groups** ("Internal",
  "External", "Prompter"…): named sets of displays managed in one settings
  panel, so a whole cue list re-routes in seconds when the rig changes. A
  group can span several displays and mirrors one decode onto all of them.
  Fit/fill/stretch, hold-last-frame or unload at end, embedded-audio routing
  to any output device, trim, loops, fades.
- **Geometry** — per-cue Fill Stage or Custom placement: position (X/Y) and
  scale the image on its stage, with a draggable mini-canvas and **live
  updates while the cue plays**. Stage-relative units, so one layout means
  the same thing on every display of a group.
- **Camera cues** — live camera input (built-in, USB/UVC, Continuity) on any
  output group; runs until stopped; fade in/out.
- **Image cues** — still images (PNG/JPEG/HEIC…) on any output group, with
  geometry and fades; holds until stopped.
- **Slide decks** — drop a PowerPoint (.pptx/.ppt) or PDF and it becomes a
  navigable deck: one group named after the file, one cue per slide, GO to
  advance, crossfade between slides, trailing clear cue. Decks are flattened
  to per-slide images at import by the best converter installed (ONLYOFFICE's
  OOXML-native engine, PowerPoint, Keynote, or LibreOffice — plain PDFs need
  nothing at all), so **nothing external ever runs during a show**.
- **Sequencing** — pre-wait, auto-continue (anchored to cue start + post-wait),
  auto-follow (fires on completion), and a playhead that skips past auto
  chains the way operators expect.
- **Groups** — fire-all-at-once, **timeline mode** with a drag-to-arrange
  editor (each child is a bar on a ruler; audio bars show waveforms), or
  **enter-and-play-first**: GO steps the playhead through the group's
  children one by one — how slide decks navigate.
- **Fade & stop cues** — target any running cue (or everything); resolved
  against live playback at fire time; fade to level or to silence with
  stop-when-done.
- **Panic** — Esc fades everything out over the show's panic duration; Esc
  twice hard-stops instantly. Hardwired, not reassignable.
- **Workspace modes** — Edit / **Show** (locks every editing surface while
  transport stays live) / **Rehearsal** (locked like Show, but video and
  camera output goes to floating, resizable preview windows — one per output
  group — so you can run the full show with no rig attached). The mode is
  saved with the show file.
- **Operator UX** — assignable keyboard shortcuts (stored in the show file)
  plus per-cue hotkeys, all suppressed while typing; Active Cues panel with
  live progress and per-instance transport; editable notes next to the GO
  button; drag media files (or whole decks) straight into the cue list;
  copy/paste/duplicate cues with reference-safe identity remapping; one-click
  renumber (10/20/30…); Open Recent; full-row color tags; collapsible groups;
  waveform/filmstrip trim editors; media relink/replace on any cue (file
  dialog or drop onto the inspector); rotating backups and
  playback-aware autosave. Dark show-control look with MagicLab styling.
- **Show files** — versioned, diff-friendly JSON (`.stagewizard`); media
  referenced relative to the show file so shows survive folder moves; old
  format versions migrate automatically on open.

## Building

Requires Xcode 26+. The Xcode project is generated, and builds land in
`./build` (ignored by git and Dropbox):

```sh
Tools/build.sh        # generate project, run all tests, build Release
Tools/package.sh      # everything above + dependency check + sign,
                      # notarize & staple (when credentials are present) + zip
```

The packaged app is self-contained (system frameworks only). Release zips on
the [releases page](https://github.com/virtualmagician/StageWizard/releases)
are Developer ID signed and notarized — download, unzip, double-click.
Without signing credentials, `package.sh` falls back to an ad-hoc build
(right-click → Open the first time).

Test media and a demo show:

```sh
swift Tools/make-test-media.swift TestMedia
open Demo.stagewizard
```

## Architecture

```
ShowModel/       pure Codable value types (the .stagewizard format)
ShowRuntime/     @MainActor cue engine: instance state machine, transport,
                 follows, ActiveCuesRegistry, MediaPlayback protocol
AudioEngineKit/  one AVAudioEngine per output device, pooled player nodes,
                 sample-accurate segment scheduling, HAL hot-plug
VideoEngineKit/  AVQueuePlayer arm pipeline (load→layer→ready→seek→preroll),
                 output windows keyed by target (display or preview),
                 camera capture, still/slide rendering, display fingerprint
                 matching, geometry
FadeKit/         one 100 Hz fade clock (≤1 dB steps, lands on exactly 0.0
                 before any stop); video opacity via render-server animations
ShortcutKit/     local event-monitor dispatcher + shortcut recorder
StageWizardApp/  SwiftUI UI, document controller, engine bridge
```

Cue *definitions* (Codable, in the show file) are strictly separated from
playback *instances* (runtime state). All orchestration is MainActor; every
AVFoundation callback hops isolation immediately; the only off-main mutations
are documented-thread-safe volume setters driven by the fade clock. 104 unit
and integration tests cover the model, sequencing semantics, the engines,
deck conversion, and full-stack playback.

## Prior art & thanks

StageWizard's cue model and engine design draw on lessons from the
open-source show-control community:

- [Linux Show Player](https://github.com/FrancescoCeruti/linux-show-player) —
  the reference for separating stored properties, operator actions, and
  runtime states, and for its generic fader design.
- [QPlayer](https://github.com/space928/QPlayer) — clean flat-list-plus-parent
  cue trees and a minimal, load-bearing follow model.
- [LivePlay](https://github.com/tdoukinitsas/liveplay) — instance-vs-definition
  separation and the "one fade-out path for every stop" contract.
- [ShowQ](https://github.com/evandelisle/showq) and
  [Cuems](https://github.com/stagesoft/cuems-engine) — cue-engine state
  machines and armed/loaded staging.
- [CasparCG](https://github.com/CasparCG) — group scheduling via per-child
  offsets.

## License

MIT — see [LICENSE](LICENSE).
