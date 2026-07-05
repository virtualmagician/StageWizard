#!/bin/zsh
# Build a distributable release zip in ./build.
# If a "Developer ID Application" certificate is present, the app is signed
# with it (hardened runtime) and — if the notary keychain profile
# "stagewizard-notary" exists — notarized and stapled, so downloads open
# without the right-click dance. Otherwise falls back to an ad-hoc build.
#
# One-time setup for notarization:
#   1. Accept the current agreements at developer.apple.com/account
#   2. Xcode → Settings → Accounts → team → Manage Certificates → +
#      → "Developer ID Application"
#   3. xcrun notarytool store-credentials stagewizard-notary \
#        --apple-id <apple-id-email> --team-id Z3U3NKMU2Y \
#        --password <app-specific password from account.apple.com>
set -e -o pipefail
cd "$(dirname "$0")/.."

Tools/build.sh

APP="build/StageWizard.app"
BINARY="$APP/Contents/MacOS/StageWizard"
VERSION=$(grep 'CFBundleShortVersionString' project.yml | sed 's/.*"\(.*\)"/\1/')

echo ""
echo "Checking for external dependencies…"
EXTERNAL=$(otool -L "$BINARY" | tail -n +2 | awk '{print $1}' \
  | grep -vE '^(/System/|/usr/lib/|@rpath/libswift|@executable_path)' || true)
if [[ -n "$EXTERNAL" ]]; then
  echo "ERROR: unexpected external dependencies:"
  echo "$EXTERNAL"
  exit 1
fi
echo "OK — system frameworks only."

DEVID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
NOTARIZED=0
if [[ -n "$DEVID" ]]; then
  echo ""
  echo "Signing with: $DEVID (hardened runtime)"
  xattr -cr "$APP"
  # --entitlements is load-bearing: re-signing without it STRIPS the
  # apple-events + camera entitlements (hardened runtime then blocks both).
  # Inside-out: embedded camera extension first, then the app.
  EXT="$APP/Contents/Library/SystemExtensions/StageWizardCamera.systemextension"
  if [[ -d "$EXT" ]]; then
    codesign --force --options runtime --timestamp \
      --entitlements Support/CameraExtension.entitlements --sign "$DEVID" "$EXT"
  fi
  # The system-extension install entitlement is RESTRICTED: without an
  # embedded Developer ID provisioning profile carrying the System Extension
  # capability, launchd refuses to spawn the app (error 163). Sign with the
  # full entitlements only when the profile is present; otherwise the app
  # ships without virtual-webcam activation (everything else works).
  APP_ENTITLEMENTS="Support/StageWizard.entitlements"
  if [[ -f "Support/StageWizard.provisionprofile" ]]; then
    cp "Support/StageWizard.provisionprofile" "$APP/Contents/embedded.provisionprofile"
    APP_ENTITLEMENTS="Support/StageWizardSigning.entitlements"
    echo "Embedded provisioning profile — virtual webcam activation enabled."
  else
    echo "No Support/StageWizard.provisionprofile — signing without the system-extension entitlement (virtual webcam activation disabled)."
  fi
  codesign --force --options runtime --timestamp \
    --entitlements "$APP_ENTITLEMENTS" --sign "$DEVID" "$APP"
  codesign --verify --strict --deep "$APP"

  if xcrun notarytool history --keychain-profile stagewizard-notary >/dev/null 2>&1; then
    echo "Submitting to Apple notary service (this can take a few minutes)…"
    NOTARY_ZIP="build/notary-upload.zip"
    ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile stagewizard-notary --wait
    rm -f "$NOTARY_ZIP"
    xcrun stapler staple "$APP"
    spctl -a -vv "$APP"
    NOTARIZED=1
  else
    echo "No 'stagewizard-notary' keychain profile — skipping notarization (see header)."
  fi
else
  echo "No Developer ID certificate — shipping ad-hoc signed (right-click → Open)."
fi

ZIP="build/StageWizard-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo ""
if [[ $NOTARIZED -eq 1 ]]; then
  echo "Package (signed + notarized + stapled): $(pwd)/$ZIP"
else
  echo "Package (NOT notarized): $(pwd)/$ZIP"
fi
du -sh "$ZIP"
