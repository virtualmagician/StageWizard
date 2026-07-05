# StageWizard — working notes for AI/dev sessions

Native macOS show control (cue-based audio/video/camera playback) for live
performance. Swift 6 strict concurrency, SwiftUI + AppKit, AVFoundation,
zero third-party dependencies. Public repo: github.com/virtualmagician/StageWizard.

## Commands

```sh
Tools/build.sh      # xcodegen → full test suite → Release build into ./build
Tools/package.sh    # build.sh + dependency check + sign + notarize + staple + zip
Tools/xcodegen/bin/xcodegen generate   # after adding/removing source files
xcodebuild -project StageWizard.xcodeproj -scheme StageWizard \
  -derivedDataPath build/DerivedData test          # tests only
swift Tools/make-test-media.swift TestMedia        # regenerate test media
```

- The `.xcodeproj` is GENERATED — edit `project.yml`, never the project.
- XcodeGen and the gh CLI are vendored in `Tools/` (gitignored; build.sh re-fetches xcodegen).
- Builds live in `./build` (gitignored + Dropbox-ignored xattr).

## Hard rules

1. **This repo is public.** Never mention specific commercial show-control
   products by name anywhere (code, comments, commits, docs). Credit
   open-source prior art only (see README "Prior art").
2. **Never push the local `full-history` branch.** The published history is a
   deliberate squash; `full-history` predates the name scrub.
3. **Every codesign invocation must pass `--entitlements
   Support/StageWizard.entitlements`** — re-signing without it silently strips
   apple-events (deck import) and camera; the hardened runtime then refuses
   the camera with no prompt while the Settings toggle looks fine.
4. **Don't remove the "Strip cloud-sync xattrs" build phases** in project.yml.
   The repo lives in Dropbox (File Provider), which tags build products with
   xattrs that make codesign fail with "detritus not allowed".
5. **Show-file compatibility:** never break decoding of older files. New model
   fields are optional or use `decodeIfPresent` with defaults; structural
   changes bump `ShowFile.currentFormatVersion` with a migration in
   `ShowFile.load`. Unknown cue types must keep decoding to `.broken`.
6. **No third-party dependencies.** `package.sh` enforces system-frameworks-only.

## Concurrency conventions (Swift 6 strict — these are load-bearing)

- All orchestration is `@MainActor`. Every AVFoundation/CoreAudio callback
  (KVO, notifications, completion handlers, HAL listeners) hops immediately
  via `Task { @MainActor in … }`.
- Closures handed to C/ObjC APIs that fire off-main MUST be `@Sendable` —
  without it they inherit MainActor isolation and the runtime TRAPS when
  invoked on another queue (this crashed GO once; see AudioDeviceManager).
- The only sanctioned off-main mutations are documented-thread-safe volume
  setters driven by `FadeClock` (the single 100 Hz fade engine).
- Never `dict[k]?.x = f(dict[k])` / `a[i].x = f(a[i])` — Swift exclusivity trap.
- Fades must land on exactly amplitude 0.0 BEFORE any stop (no-click invariant).

## Architecture map

- `Sources/ShowModel/` — pure Codable value types = the `.stagewizard` format.
- `Sources/ShowRuntime/` — cue engine: `CueInstance` state machine,
  `TransportController` (GO/follows/panic), `ActiveCuesRegistry`,
  `MediaPlayback` protocol, `CuePlayerProviding`.
- `Sources/AudioEngineKit/` — one AVAudioEngine per output device, pooled
  player nodes, sample-accurate `scheduleSegment` trim, HAL hot-plug.
- `Sources/VideoEngineKit/` — video + camera + still (slide) players,
  `OutputTarget` (real display | rehearsal preview), `OutputWindowManager`
  (leased windows), `DisplayManager` (fingerprint matching), geometry
  transforms.
- `Sources/FadeKit/` — FadeClock + curves.
- `Sources/ShortcutKit/` — local keyDown monitor + recorder (Esc = panic,
  hardwired; pass-through while text editing / sheets).
- `Sources/StageWizardApp/` — SwiftUI UI, `ShowDocumentController` (manual
  JSON save/open, rotating backups, playback-aware autosave), `AppModel`
  (composition root, workspace modes), `EngineBridge` (arm resolution).

## Semantics pinned by tests (don't "fix" these)

- Stopping a cue (stop cue / Stop All / panic) NEVER fires its auto-follow.
- Auto-continue anchors to cue START + post-wait; auto-follow to completion.
- GO past the last cue goes dead — no wraparound.
- Video/camera/image/slide cues REQUIRE an output group (no implicit main-display target).
- Slides replace each other on the same output; standalone image cues LAYER (like video).
- Render layers 1-10 (zPosition on player layers/containers); default 5; ties
  break by ARM ORDER — that tie-break is what keeps slide crossfades working.
- Text cues render RTF to a 2x bitmap at stage size (TextCuePlayer); edits and
  preview resizes re-render; model stays AppKit-free (RGBAColor, plainPreview).
- Camera effects (CameraEffects on CameraBody, default all-off): passthrough
  preview layer vs processed path (CameraFrameProcessor: data output on its own
  queue -> Vision segmentation/hand pose -> CoreImage -> CGImage to content
  layers). Each camera target = container layer (fade/z/transform) holding
  preview + content + up to 2 hand emitters. Effects swap LIVE (no session
  restart; data connection disabled when idle). Mirroring pushed into the
  capture connection when supported, else flipped in the processor.
- .pex (Particle Designer) emitters map onto CAEmitterLayer (PEXEmitter.swift);
  texture = base64 + gzip (header stripped, raw-DEFLATE via Compression);
  additive blend deliberately approximated with plain alpha.
- Fade cue with no target is a warned no-op; targeting a group reaches children.
- Output groups may span displays → one decode mirrors to N layers.
- Rehearsal mode routes video/camera to floating preview windows only.
- Launch auto-opens the most recent still-existing show (unless opened via
  Finder); quit is guarded twice: locked-workspace confirm, then dirty-save.
  AppDelegate.appModel is re-wired in the scene's onAppear — App re-inits
  would otherwise nil the weak ref and silently disable both guards.
- Slide cues hold until stopped; starting a slide crossfades out other slides
  on the SAME output group only. Decks are flattened at IMPORT (never any
  external process at showtime) via `SlideDeckImporter`'s probed chain:
  ONLYOFFICE x2t (needs BOTH font params or glyphs garble) → PowerPoint →
  Keynote (AppleScript export, apple-events entitlement) → LibreOffice
  headless (private profile flag is load-bearing) → PDF via PDFKit
  (zero-dependency floor). Rendered PNGs live in
  ~/Library/Application Support/StageWizard/SlideCache/.

## Release / credentials (machine-local, no secrets in repo)

- Developer ID cert (team Z3U3NKMU2Y) + notary keychain profile
  `stagewizard-notary` live in the macOS keychain; `package.sh` auto-detects
  both. Missing → falls back to ad-hoc zip.
- GitHub pushes: token in keychain; repo-local `credential.username` is pinned
  (a stale keychain entry otherwise wins and 403s).
- Ship a release: bump `CFBundleShortVersionString` in project.yml →
  `Tools/package.sh` → `gh release create vX.Y.Z build/StageWizard-X.Y.Z.zip`
  (gh at `Tools/gh-cli/bin/gh`, auth via
  `GH_TOKEN=$(printf "protocol=https\nhost=github.com\nusername=virtualmagician\n" | git credential-osxkeychain get | grep '^password=' | cut -d= -f2)`).

## Known v1 limitations (documented, not bugs)

Audio exit-loop plays up to one extra queued pass; device unplug stops (not
migrates) its cues; pause doesn't freeze in-flight fades; follows inside
groups are ignored (timeline offsets sequence children); no undo (rotating
`.stagewizard-backups/` next to the show file); prefer ProRes for loop-heavy
video. `Media/` (real show media) and `TestMedia/` are gitignored.
