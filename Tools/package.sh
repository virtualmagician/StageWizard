#!/bin/zsh
# Build a distributable, dependency-free release zip in ./build.
# The app uses only system frameworks; this script verifies that before
# packaging. Ad-hoc signed: on another Mac, right-click → Open the first time.
set -e
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

ZIP="build/StageWizard-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo ""
echo "Package: $(pwd)/$ZIP"
du -sh "$ZIP"
