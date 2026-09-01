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
- THIS MACHINE: `xcode-select` points at CommandLineTools (no sudo to fix) —
  prefix every xcodebuild/xcodegen with
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer &&`.

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
  player nodes (each player→varispeed→mixer; the 32 varispeed units attach at
  buildEngine — mid-show attach/detach stays forbidden), sample-accurate
  `scheduleSegment` trim, HAL hot-plug.
- `Sources/VideoEngineKit/` — video + camera + still (slide) players,
  `OutputTarget` (real display | rehearsal preview), `OutputWindowManager`
  (leased windows), `DisplayManager` (fingerprint matching), geometry
  transforms.
- `Sources/FadeKit/` — FadeClock + curves.
- `Sources/ShortcutKit/` — local keyDown monitor + recorder (Esc = panic,
  hardwired; pass-through while text editing / sheets).
- `Sources/StageWizardApp/` — SwiftUI UI, `ShowDocumentController` (manual
  JSON save/open, rotating backups, playback-aware autosave, snapshot undo at
  the `mutate()` funnel), `AppModel` (composition root, workspace modes),
  `EngineBridge` (arm resolution), and the remote-control stack:
  `TriggerRouter` (the ONLY path remote triggers take into perform()/fire —
  MIDI, OSC, web remote, and gesture GO all end here), `MIDIController`
  (CoreMIDI + MIDI-Learn), `OSCServer` (UDP, default port 53100),
  `WebRemoteServer` + `WebRemotePage` (TCP HTTP, default port 53200, embedded
  phone page), `StageDisplayWindow` (performer confidence monitor, window
  level screenSaver−1 so real outputs cover it), `PreflightCheck`. Both
  network ports are per-show settings, off by default, unauthenticated by
  design (LAN-only; `NSLocalNetworkUsageDescription` lives in project.yml).
- Stage display v2: pane-driven (normalized y-down rects, edited on a 16:9
  snap canvas; program panes are per-output-group, 16:9-locked = h==w on
  the reference canvas). Program mirroring = OutputWindowManager EXTERNAL
  HOST registration (per-group target id = group UUID XOR 0x33 sentinel);
  resolveTargets appends it at arm AND AppModel.syncMirrorAttachments
  attaches/detaches RUNNING players live (MediaPlayback.attach/detachTarget,
  second AVPlayerLayer on the same player, presentation-value opacity).
  Paint order inside the window is explicit zPosition (panes 0, program
  100, panic 1000) — AppKit reorders layer-backed sublayer arrays
  asynchronously, insertSublayer(below:) is NOT reliable there. Fullscreen
  NEVER covers the screen hosting the operator window (floats instead —
  presentationStyle is the pure decision); ⌘⎋ (hardwired, monitor +
  menu-item double path, works with nil/non-key window) always exits Show
  mode. OutputGroup.floatingWindow routes a group to its preview window in
  EVERY mode.
- OSC feedback (StageWand contract): any sender heard <5 s is a subscriber
  (/stagewand/ping = keepalive); new subscriber → full refresh on its own
  UDP flow; /stagewizard/status/standingby|running|panic|showmode|window|
  notes on change (10 Hz diff of the SAME snapshot the web remote serves),
  /status/elapsed at 2 Hz while running (duration −1 = indefinite);
  /stagewizard/cue/{n}/select stands by without firing; Bonjour
  _stagewizard._udp. P3 faders were SCRAPPED (2026-09-01): the wand's
  fourth page is a transport page using the existing /toggle /stopall
  /panic verbs — never re-propose /stagewizard/level.
  D22: /status/running also re-sends unconditionally every ~2 Hz (tick %
  20) as a liveness heartbeat, suppressed on ticks that already sent a
  genuine change. D22: /stagewizard/cuelist/begin|item|end dumps the GO
  sequence (number, name), capped at 64, on subscribe (after the status
  messages) and whenever it changes.

## Semantics pinned by tests (don't "fix" these)

- Stopping a cue (stop cue / Stop All / panic) NEVER fires its auto-follow.
- Auto-continue anchors to cue START + post-wait; auto-follow to completion;
  auto-continue-at-marker anchors to START + preWait + (markerTime − trimIn)
  ÷ rate. A deleted marker = silent no-arm. Single-cue stop does NOT cancel
  pending follows (pinned); Stop All / panic does. Format v4 = marker
  follows (old apps must refuse v4 files cleanly — their FollowAction
  decoder throws on the unknown mode).
- Playback rate (0.25×–4×, audio varispeed = tape-style pitch shift):
  sample/media-time scheduling is untouched; `duration`/`currentTime` and
  every authored fade-out delay report WALL-CLOCK (media ÷ rate). Varispeed
  rate resets to 1 on pool checkin.
- Wall-clock triggers: 1 Hz tick, fires in (prevTick, nowTick] once per cue
  per day; the FIRST tick after enabling only baselines (times already
  passed today never backfire); midnight wrap resets the day; panic
  suppresses; Edit mode never ticks.
- Undo restore does NOT go through onDocumentReplaced (that would stop
  playback) — it fires onUndoRestore, transport just revalidates the
  playhead. rebaseMediaReferences (during save) records nothing.
- Remote semantics: MIDI noteOn fires, noteOff never, CC only on the
  transition into ≥64 (held pedal can't machine-gun GO); gesture GO needs a
  a 1 s continuous hold of the cue's chosen pose (openPalm | fist |
  thumbsUp | handsTogether; thumbsUp suppresses fist; handsTogether needs
  2 hands), then a 3 s cooldown demanding a fresh hold, and
  never fires in Edit mode; the web page carries no panic button (emergency
  stays physical). Panic is not a ShortcutAction — remotes reach it via
  TriggerRouter.routePanic() → transport.panic(), same as Esc.
- GO past the last cue goes dead — no wraparound.
- Video/camera/image/slide cues REQUIRE an output group (no implicit
  main-display target) — EXCEPT D25 `CameraBody.sensorOnly`: a camera cue
  running purely as a hand-gesture sensor draws to no output at all, so it
  needs no group (`EnginePlayerProvider.resolveTargets` returns `[]` for it
  without throwing, skipping the virtual-webcam/program-mirror extras too —
  nothing draws, so nothing mirrors; Preflight and the cue-list warning icon
  are exempted the same way). This is the ONE deliberate carve-out in the
  rule; every other visual cue type still requires a group.
- Slides replace each other on the same output; standalone image cues LAYER (like video).
- Render layers 1-10 (zPosition on player layers/containers); default 5; ties
  break by ARM ORDER — that tie-break is what keeps slide crossfades working.
- Text cues render RTF to a 2x bitmap at stage size (TextCuePlayer); edits and
  preview resizes re-render; model stays AppKit-free (RGBAColor, plainPreview).
- Camera effects (CameraEffects on CameraBody, default all-off): passthrough
  preview layer vs processed path (CameraFrameProcessor: data output on its own
  queue -> mirror -> chroma key (CIColorCube, YCbCr distance, cube rebuilt
  only on param change) -> Vision segmentation/hand pose -> CoreImage ->
  CGImage to content layers; chroma-only skips Vision entirely; gesture GO
  classification is queue-confined and hops value types out). Each camera target = container layer (fade/z/transform) holding
  preview + content + up to 2 hand emitters. Effects swap LIVE (no session
  restart; data connection disabled when idle). Mirroring pushed into the
  capture connection when supported, else flipped in the processor.
- D25: gesture GO's warm-up hold is selectable per cue
  (`CameraEffects.gestureHoldSeconds`, 0.25...5 s, default 1.0 — clamped on
  init AND decode; `GestureHoldDetector.holdDuration` is now an init param,
  not a fixed constant; cooldown stays fixed at 3 s). `CameraBody.sensorOnly`
  runs the camera as a hand-gesture sensor ONLY: no window/host lease, no
  preview/content layers, no container (`CameraCuePlayer` forces this at the
  `arm` boundary regardless of what targets it's handed); fades, geometry
  pushes, and attach/detach all no-op; segmentation/magicDust/chromaKey are
  force-reduced off (`CameraCuePlayer.effectiveEffects`) since nothing ever
  draws — gestureGo/goGesture/gestureHoldSeconds are untouched, since gesture
  tracking is the entire point.
- .pex (Particle Designer) emitters map onto CAEmitterLayer (PEXEmitter.swift);
  texture = base64 + gzip (header stripped, raw-DEFLATE via Compression);
  additive blend deliberately approximated with plain alpha.
- Fade cue with no target is a warned no-op; targeting a group reaches children.
- Output groups may span displays → one decode mirrors to N layers.
- Rehearsal mode routes video/camera to floating preview windows only —
  and stays fully EDITABLE (only Show mode locks; isShowMode == (mode == .show)).
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

## Virtual webcam ("StageWizard Camera")

- CMIO camera system extension (Sources/CameraExtension, target
  StageWizardCamera) embedded at Contents/Library/SystemExtensions; source
  stream = what Zoom sees, sink stream = fed by the app (CMSimpleQueue).
- Feed path: cues render into the pinned "Virtual Webcam" preview panel
  (OutputTarget.preview id 2222…), ScreenCaptureKit streams that window at
  1080p30 into the sink (VirtualCameraManager). Needs Screen Recording TCC.
- The restricted `com.apple.developer.system-extension.install` entitlement
  lives ONLY in Support/StageWizardSigning.entitlements — AND may only be
  signed in when `Support/StageWizard.provisionprofile` (a Developer ID
  provisioning profile with the System Extension capability, from the Apple
  developer portal) is present to embed; otherwise launchd REFUSES TO SPAWN
  the app (error 163). The scripts handle this automatically and fall back
  to the unrestricted entitlements. The profile IS committed (public repo:
  profiles hold no secrets — certs + entitlements only; useless without the
  private key) and is valid until 2044-06-30. Scripts sign INSIDE-OUT: extension (its
  own entitlements) → app.
- Activation needs the app in /Applications + one-time user approval; the
  extension's mach service name is hardcoded team-prefixed in project.yml.
- HARD-WON extension lessons (each cost a debugging round):
  * sysextd requires the extension bundle NAMED by its bundle id
    (<id>.systemextension), CFBundlePackageType SYSX, an
    NSSystemExtensionUsageDescription, and a team-prefixed app-group
    entitlement for the mach service namespace.
  * Every NEW extension version must be NOTARIZED or activation fails with
    "code signature invalid" — extension changes go through package.sh;
    app-only changes can use build.sh (no re-activation needed).
  * SCK sample buffers do NOT survive the CMIO XPC hop (consumeSampleBuffer
    fails, OSStatus -6) — the app repackages each frame's IOSurface pixel
    buffer via CMSampleBufferCreateReadyWithImageBuffer.
  * The extension's consume-retry must never dispatch back onto stateQueue
    (consumeBuffer syncs on it → self-deadlock → process killed → respawn
    with no sink client; app-side queue jams full silently).
  * SCK is change-driven → app repeat-sends the last frame at 30 fps; window
    capture needs scalesToFit + a sourceRect crop excluding the title bar
    (tracked across resizes); preview panels have hidesOnDeactivate=false so
    backgrounding the app doesn't starve the camera.
  * Feed diagnostics: /usr/bin/log show --info --predicate
    'subsystem == "com.marcotempest.stagewizard"' (or .camera for the
    extension). FULL PATH — plain `log` is shadowed by a shell alias here;
    --info is required (Logger .info is memory-only by default).

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

## Known limitations (documented, not bugs)

Audio exit-loop plays up to one extra queued pass; device unplug stops (not
migrates) its cues; pause doesn't freeze in-flight fades; follows inside
groups are ignored (timeline offsets sequence children); undo is
snapshot-based with a 100-step cap (rotating `.stagewizard-backups/` remain
the deep-history net); OSC/web remote are unauthenticated by design (off by
default, trusted show LAN only); prefer ProRes for loop-heavy video.
`Media/` (real show media) and `TestMedia/` are gitignored.
