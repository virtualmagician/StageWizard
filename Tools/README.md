# Tools

- `build.sh` — generate project, run tests, build Release (re-downloads xcodegen if missing).
- `xcodegen/` — vendored [XcodeGen 2.44.1](https://github.com/yonaskolb/XcodeGen) binary (gitignored; build.sh re-fetches it).
- `make-test-media.swift` — generates `TestMedia/` (tone/count WAVs, counter videos with beep tracks).
- `make-demo-show.swift` — regenerates `Demo.stagewizard`:
  `swiftc -parse-as-library Sources/ShowModel/*.swift Tools/make-demo-show.swift -o /tmp/mds && /tmp/mds`
