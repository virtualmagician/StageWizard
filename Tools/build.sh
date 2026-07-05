#!/bin/zsh
# Generate the Xcode project, run the full test suite, and build Release.
# Build products live in ./build (gitignored, Dropbox-ignored).
set -e -o pipefail
cd "$(dirname "$0")/.."

if [[ ! -x Tools/xcodegen/bin/xcodegen ]]; then
  echo "xcodegen missing — downloading pinned release…"
  curl -sL -o Tools/xcodegen.zip \
    "https://github.com/yonaskolb/XcodeGen/releases/download/2.44.1/xcodegen.zip"
  (cd Tools && unzip -oq xcodegen.zip && rm xcodegen.zip)
fi

Tools/xcodegen/bin/xcodegen generate

if [[ ! -d TestMedia ]]; then
  echo "Generating test media…"
  swift Tools/make-test-media.swift TestMedia
fi

# In-project builds; keep Dropbox from syncing the churn.
mkdir -p build
xattr -w com.dropbox.ignored 1 build 2>/dev/null || true

DERIVED="build/DerivedData"

# pipefail is load-bearing: a test failure must abort the build/package.
xcodebuild -project StageWizard.xcodeproj -scheme StageWizard \
  -derivedDataPath "$DERIVED" test | grep -E "Test Suite|Executed|\*\*"
xcodebuild -project StageWizard.xcodeproj -scheme StageWizard \
  -configuration Release -derivedDataPath "$DERIVED" build | grep -E "error|\*\*"

rm -rf build/StageWizard.app
cp -R "$DERIVED/Build/Products/Release/StageWizard.app" build/StageWizard.app

# Sign dev builds with the Developer ID cert when it's present. TCC keys
# permission grants (camera!) to the signing identity — ad-hoc builds get a
# fresh identity every compile, so camera access would break on each rebuild
# and mismatch the notarized copies. Same detection as package.sh.
DEVID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
if [[ -n "$DEVID" ]]; then
  xattr -cr build/StageWizard.app
  # Inside-out: the embedded camera extension first (with ITS entitlements),
  # then the app — the app seal covers the extension.
  EXT="build/StageWizard.app/Contents/Library/SystemExtensions/StageWizardCamera.systemextension"
  if [[ -d "$EXT" ]]; then
    codesign --force --options runtime --timestamp \
      --entitlements Support/CameraExtension.entitlements \
      --sign "$DEVID" "$EXT"
  fi
  codesign --force --options runtime --timestamp \
    --entitlements Support/StageWizardSigning.entitlements \
    --sign "$DEVID" build/StageWizard.app
  echo "Signed with: $DEVID"
fi

echo ""
echo "Built: $(pwd)/build/StageWizard.app"
echo "Install with:  cp -R build/StageWizard.app /Applications/"
