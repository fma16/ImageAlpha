# ImageAlpha

ImageAlpha is a Mac OS X GUI for [pngquant](http://pngquant.org), with optional lossless optimization via [oxipng](https://github.com/oxipng/oxipng) and extra (very slow) compression via [zopflipng](https://github.com/google/zopfli).

ImageAlpha is written in Python and Cocoa (PyObjC).

![Screenshot](https://pngmini.com/screenshot-1.3.png)

## Apple Silicon security rebuild

This fork targets **macOS 13+ on arm64 only**. It does not build or test Intel
support. The upstream v2.0.0b1 release is not a patched distribution.

The arm64 release contains libpng 1.6.54 in both pngquant's dynamic library and
posterize's statically linked copy. These contain the vulnerable ARM Neon palette
expansion routines described in [CVE-2026-33636](https://github.com/pnggroup/libpng/security/advisories/GHSA-wjr5-c57x-95m2).
That issue was fixed in 1.6.56, but this fork uses **1.6.59**, the current stable
release verified on 2026-11-04. It also includes subsequent fixes, including
[CVE-2026-46675](https://github.com/pnggroup/libpng/security/advisories/GHSA-qvg3-h654-xq3j).
See the [official release page and SHA-256 checksums](https://www.libpng.org/pub/png/libpng.html).

| Component | Pinned input | Linking |
| --- | --- | --- |
| pngquant | 3.0.3, published crates.io archive | Bundled libpng and Little CMS dylibs |
| libpng | 1.6.59, official source archive | Dynamic in pngquant; static in posterize |
| Little CMS | 2.19.1, official source archive | Dynamic in pngquant; runtime API reports 2190 |
| posterize | upstream commit `177bcac74f56c022cb62ff5099e9e16faced856c` | Bundled libpng static archive |

### Rebuild

Install Apple's Command Line Tools, Rust/Cargo, pkg-config and Python 3. Full
Xcode is needed only to build the Cocoa application, not these command-line tools.

```sh
./build-arm64-tools.sh
```

The script verifies hard-coded SHA-256 hashes **before extraction** and builds
both tools from source. The pngquant archive's Cargo.lock is also hash-checked;
`cargo build --locked` checks and pins transitive crate downloads. It does not
copy host Homebrew libraries or build Cargo's vendored libpng fallback. libpng
and Little CMS run their upstream test suites. The script verifies arm64 slices,
runtime dylib versions and relative load paths, then replaces the matching set
of tools and libraries in `Tools/`. zlib remains the macOS system library.

Sources and intermediate products stay in ignored `build/arm64-tools/`. A
temporary symlink avoids Autotools' problems with spaces in checkout paths.
Version-pinned inputs do not imply byte-for-byte reproducible Mach-O outputs
across compiler/SDK versions. Third-party notices are in `Tools/licenses/`.

### Validate

Use a Python environment containing Pillow (validation used Pillow 12.0.0):

```sh
python3 -m venv build/test-venv
build/test-venv/bin/pip install Pillow==12.0.0
build/test-venv/bin/python test_png_tools.py
```

The tests exercise the actual binaries via stdin/stdout, compare decoded pixels
with independently specified values, cover indexed RGB/RGBA tails at 4/8-pixel
boundaries (including widths 5 and 9), quality/dither/blur modes, truncated input
and the runtime libpng security floor. There are 75 processing scenarios.
An optional argument selects a signed app's `Contents/MacOS` directory instead
of `Tools/`.

Validation on native macOS arm64 (2026-11-04): libpng's **36/36** upstream tests,
Little CMS's testbed, and the processing tests passed. A separate scratch probe
of the actual release dylib's Neon routines overwrote 12 prefix bytes at RGBA
width 5 and 21 at RGB width 9; the rebuilt dylib overwrote zero and returned the
correct destination pointers. This is a direct routine-level check, **not an
end-to-end exploit demonstration in the GUI**. Ordinary processing tests also
pass on the old release and alone do not prove memory safety.
Additional smoke checks preserved exact pixels for RGB, RGBA, 8-bit grayscale
and 16-bit grayscale inputs with zTXt/iTXt metadata and, for RGB/RGBA, an sRGB
iCCP profile.

### Application packaging and signing

The Xcode build phase runs `bundle-pngquant-libs.sh` before signing. It copies
**both** rebuilt tools, the exact matching dylibs and license notices, without
fetching dependencies. Replacing just the dylib would leave posterize vulnerable.
For manual packaging, run the same script on the app before signing it.

**Do not run an already signed app after replacing its contents without
re-signing it.** macOS correctly treats that bundle's original signature as
invalid and may display an “app is damaged” alert, even for nested CLI tools.
Do not disable Gatekeeper or remove quarantine as a workaround.

The checked-in tools carry ad-hoc signatures for local development, not a
Developer ID or notarization. The rebuilt Cocoa app was signed ad-hoc without
hardened runtime for local validation and passed `codesign --verify --deep
--strict` both before and after launch and document processing. Python bytecode
cache writes are disabled at interpreter initialization: otherwise importing
modules creates files inside the sealed Python framework and invalidates its
signature after launch. This is not a
distributable notarized app: production signing requires a Developer ID with
consistent Team IDs for the nested tools/dylibs and notarization by Apple.
The existing production signing script retains hardened runtime.

### Cocoa validation on Apple Silicon

A clean Release build completed on **macbook-bold**, native arm64 macOS 26.6.1,
on 2026-11-06 with Xcode 27.2 (27B52), targeting arm64 only. The global developer
directory was left unchanged; this runner selected full Xcode per command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ImageAlpha.xcodeproj -scheme ImageAlpha \
  -configuration Release -derivedDataPath build/CocoaValidated \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
codesign --force --deep --sign - --options 0 \
  build/CocoaValidated/Build/Products/Release/ImageAlpha.app
```

The 75 PNG-processing scenarios passed against the tools in that new app bundle;
the existing compression-settings suite passed all 55 checks. Validation used
Pillow 12.0.0 with Python 3.13. Run external tests with `-B` and export
`PYTHONDONTWRITEBYTECODE=1` for child interpreters too, to preserve tracked caches
in the source framework.

Accessibility and Screen Recording permissions were granted through macOS's
standard authorization flow. Real native controls and File > Save As sheets
were exercised, and seven WindowServer captures were inspected (not AppKit
cached-view captures). Cases covered pngquant 256 + oxipng, pngquant 32 without
dithering or lossless optimization, posterize 16 without blur or optimization,
posterize Quality 80 + blur + oxipng, pngquant Quality 80 + zopflipng, and Show
original. The real Colors/Levels slider was changed with AXDecrement, not by
changing the text field alone.

All five native Save As outputs decoded at 640 × 440 and matched the exact RGBA
pixels of independently executed CLI commands for the requested settings. The
pngquant 32 output had exactly 32 colors and retained alpha from 0 to 255.
User ImageAlpha preferences were backed up and restored. The ad-hoc signature
passed `codesign --verify --deep --strict` before launch and after all processing
and saves. Gatekeeper remained enabled; its distribution assessment rejected
this unnotarized ad-hoc build, as expected. No archive, notarization, publication,
or app installation was performed.

An earlier validation on the source Mac also used a temporary hosted XCTest.
It established that the original release and rebuilt posterize produce
byte-identical output for the tested `-b 16` input, including its pre-existing
severe image degradation and loss of transparency; that behavior is unchanged.
