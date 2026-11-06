#!/bin/bash
# Rebuild the PNG decoders from checksum-pinned sources. macOS arm64 only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ "$(uname -s)/$(uname -m)" != Darwin/arm64 ]; then
    echo 'This build requires native Apple Silicon macOS.' >&2
    exit 1
fi
for tool in clang make cargo pkg-config curl shasum python3; do
    command -v "$tool" >/dev/null
done

# Autotools cannot reliably handle spaces in paths. The symlink keeps all
# downloads and build products inside this checkout, even in "VS Code".
SHORT="$(mktemp -d /tmp/imagealpha-arm64.XXXXXX)"
trap 'rm -f "$SHORT/repo"; rmdir "$SHORT"' EXIT
ln -s "$ROOT" "$SHORT/repo"
WORK="$SHORT/repo/build/arm64-tools"
PREFIX="$WORK/prefix"
mkdir -p "$WORK" "$PREFIX" "$ROOT/Tools"

fetch() {
    local name="$1" sha="$2" url="$3"
    if [ ! -f "$WORK/$name" ]; then
        curl --fail --location --proto '=https' --proto-redir '=https' \
            "$url" -o "$WORK/$name"
    fi
    echo "$sha  $WORK/$name" | shasum -a 256 -c -
}

# libpng/pngquant/lcms hashes independently cross-checked with Homebrew core.
# posterize is an immutable upstream commit; its archive hash is pinned here.
fetch libpng.tar.xz d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389 \
    https://downloads.sourceforge.net/project/libpng/libpng16/1.6.59/libpng-1.6.59.tar.xz
fetch pngquant.crate 68a12bdd8825f9989f4ee9a6ab0b42727dae57728b939ef63453366697a07232 \
    https://static.crates.io/crates/pngquant/pngquant-3.0.3.crate
fetch lcms.tar.gz bfc54f7bab59fbc921012014a8032e4cba4abd46db47d46b76416a8c0b2815c8 \
    https://downloads.sourceforge.net/project/lcms/lcms/2.19.1/lcms2-2.19.1.tar.gz
fetch posterize.tar.gz 88ff10aed6131ce4092b9bfb03478fdab0b180a56ebc483b662cb191f6ea95fb \
    https://codeload.github.com/kornelski/mediancut-posterizer/tar.gz/177bcac74f56c022cb62ff5099e9e16faced856c

# Clean only generated source trees; retain checksum-verified download caches.
# In particular, do not reuse objects containing an earlier temporary prefix.
rm -rf "$WORK/libpng-1.6.59" "$WORK/lcms2-2.19.1" "$WORK/pngquant-3.0.3" \
    "$WORK/mediancut-posterizer-177bcac74f56c022cb62ff5099e9e16faced856c"
for archive in libpng.tar.xz pngquant.crate lcms.tar.gz posterize.tar.gz; do
    tar xf "$WORK/$archive" -C "$WORK"
done
export MACOSX_DEPLOYMENT_TARGET=13.0
export CC=clang
export CFLAGS='-O2 -arch arm64 -mmacosx-version-min=13.0'
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$(xcrun --show-sdk-path)/usr/lib/pkgconfig"
export CARGO_HOME="$WORK/cargo-home"
export LCMS2_INCLUDE_DIR="$PREFIX/include"
export LCMS2_LIB_DIR="$PREFIX/lib"
JOBS="$(sysctl -n hw.ncpu)"

(
    cd "$WORK/libpng-1.6.59"
    ./configure --prefix="$PREFIX" --enable-static --enable-shared
    make -j"$JOBS"
    make check
    make install
)
(
    cd "$WORK/lcms2-2.19.1"
    ./configure --prefix="$PREFIX" --disable-static --enable-shared \
        --without-jpeg --without-tiff
    make -j"$JOBS"
    make install
    # LCMS's test target uses LD_LIBRARY_PATH, which dyld ignores on macOS.
    # Install into our private prefix first so testcms can load its dylib.
    make check
)
(
    cd "$WORK/pngquant-3.0.3"
    # The published crate includes Cargo.lock with checksums for all crates.
    echo '80be78015298fc8e4a964eab70a57b85888cbb22c01e4954c016f03de3ba0abe  Cargo.lock' | shasum -a 256 -c -
    cargo build --release --locked --target aarch64-apple-darwin
)
POSTERIZE="$WORK/mediancut-posterizer-177bcac74f56c022cb62ff5099e9e16faced856c"
clang $CFLAGS -I"$PREFIX/include" \
    "$POSTERIZE/posterize.c" "$POSTERIZE/rwpng.c" "$POSTERIZE/blurize.c" \
    "$PREFIX/lib/libpng16.a" -lz -o "$WORK/posterize"

cp "$WORK/pngquant-3.0.3/target/aarch64-apple-darwin/release/pngquant" "$WORK/pngquant"
cp "$PREFIX/lib/libpng16.16.dylib" "$WORK/libpng16.16.dylib"
cp "$PREFIX/lib/liblcms2.2.dylib" "$WORK/liblcms2.2.dylib"
for lib in libpng16.16.dylib liblcms2.2.dylib; do
    install_name_tool -change "$PREFIX/lib/$lib" "@executable_path/$lib" "$WORK/pngquant"
    install_name_tool -id "@executable_path/$lib" "$WORK/$lib"
done
for tool in pngquant posterize libpng16.16.dylib liblcms2.2.dylib; do
    codesign --force --sign - "$WORK/$tool"
    test "$(lipo -archs "$WORK/$tool")" = arm64
done
# Fail rather than silently accepting a vendored fallback or Homebrew library.
python3 - "$WORK" <<'PY'
import ctypes
import sys
from pathlib import Path
tools = Path(sys.argv[1])
png = ctypes.CDLL(str(tools / 'libpng16.16.dylib'))
png.png_get_libpng_ver.restype = ctypes.c_char_p
assert png.png_get_libpng_ver(None) == b'1.6.59'
cms = ctypes.CDLL(str(tools / 'liblcms2.2.dylib'))
assert cms.cmsGetEncodedCMMversion() == 2190
print('Runtime libraries: libpng 1.6.59, Little CMS 2.19.1 (encoded 2190)')
PY
otool -L "$WORK/pngquant" | grep '@executable_path/libpng16.16.dylib'
otool -L "$WORK/pngquant" | grep '@executable_path/liblcms2.2.dylib'
if otool -L "$WORK/pngquant" "$WORK/posterize" | grep -E '^[[:space:]]+/(opt/homebrew|usr/local|tmp)/'; then
    echo 'Unexpected non-system dependency' >&2
    exit 1
fi
cp "$WORK/pngquant" "$WORK/posterize" "$WORK/libpng16.16.dylib" "$WORK/liblcms2.2.dylib" "$ROOT/Tools/"
mkdir -p "$ROOT/Tools/licenses"
cp "$WORK/pngquant-3.0.3/COPYRIGHT" "$ROOT/Tools/licenses/pngquant.txt"
cp "$WORK/libpng-1.6.59/LICENSE" "$ROOT/Tools/licenses/libpng.txt"
cp "$WORK/lcms2-2.19.1/LICENSE" "$ROOT/Tools/licenses/lcms2.txt"
shasum -a 256 "$ROOT/Tools/pngquant" "$ROOT/Tools/posterize" "$ROOT/Tools/"*.dylib
