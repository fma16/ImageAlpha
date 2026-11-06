#!/bin/bash
set -euo pipefail

# Bundle only the tools and matching libraries from the pinned arm64 build.
# Copy posterize too: replacing the dylib alone leaves its static libpng stale.
# Run BEFORE signing. Never source dependencies from the host's Homebrew.
# Usage: ./bundle-pngquant-libs.sh /path/to/ImageAlpha.app

if [ $# -ne 1 ]; then
    echo "Usage: $0 /path/to/ImageAlpha.app"
    exit 1
fi

APP="$1"
MACOS_DIR="$APP/Contents/MacOS"
TOOLS="$(cd "$(dirname "$0")" && pwd)/Tools"

if [ ! -d "$MACOS_DIR" ]; then
    echo "ERROR: app executable directory not found at $MACOS_DIR"
    exit 1
fi

for tool in pngquant posterize libpng16.16.dylib liblcms2.2.dylib; do
    test "$(lipo -archs "$TOOLS/$tool")" = arm64
    codesign --verify --strict "$TOOLS/$tool"
done
cp -f "$TOOLS/pngquant" "$TOOLS/posterize" "$TOOLS/"*.dylib "$MACOS_DIR/"
mkdir -p "$APP/Contents/Resources/ToolLicenses"
cp "$TOOLS/licenses/"*.txt "$APP/Contents/Resources/ToolLicenses/"
# Do not execute nested code until the app has been re-signed: an existing
# bundle signature is invalid after these replacements, even for --version.
echo 'Pinned arm64 tools bundled. Sign the app before distribution.'
