#!/usr/bin/env python3
"""Exercise the shipped PNG decoders through the same stdin interface as the app.

Requires Pillow as an independent output decoder. Optional argument: a directory
containing the tools (e.g. ImageAlpha.app/Contents/MacOS).
"""
import ctypes
import io
from pathlib import Path
import struct
import subprocess
import sys
import unittest
import zlib

from PIL import Image

TOOLS = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path(__file__).parent / "Tools"


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def palette_png(width, transparent):
    # Hand-built 8-bit indexed input: do not let an encoder reduce bit depth,
    # which would bypass the ARM Neon palette expansion under test.
    height = 3
    palette = [(255, 0, 0), (0, 255, 255), (0, 0, 255), (255, 255, 0)]
    alphas = [255, 128, 255, 128] if transparent else [255] * 4
    indices = [[(x + 3 * y) % 4 for x in range(width)] for y in range(height)]
    expected = [(*palette[i], alphas[i]) for row in indices for i in row]
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0))
    data += chunk(b"PLTE", bytes(c for rgb in palette for c in rgb))
    if transparent:
        data += chunk(b"tRNS", bytes(alphas))
    data += chunk(b"IDAT", zlib.compress(b"".join(b"\0" + bytes(row) for row in indices)))
    return data + chunk(b"IEND", b""), expected


class PngToolsTests(unittest.TestCase):
    def test_libpng_security_floor(self):
        libpng = ctypes.CDLL(str(TOOLS / "libpng16.16.dylib"))
        libpng.png_get_libpng_ver.restype = ctypes.c_char_p
        version = tuple(map(int, libpng.png_get_libpng_ver(None).decode().split(".")))
        self.assertGreaterEqual(version, (1, 6, 59))

    def convert(self, tool, args, data):
        result = subprocess.run([str(TOOLS / tool), *args], input=data, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        image = Image.open(io.BytesIO(result.stdout))
        image.load()
        return image.convert("RGBA")

    def test_neon_palette_tails(self):
        # Full chunks, scalar-only rows and every tail on both sides of the
        # 4/8-pixel boundaries. Includes the advisory's minimal widths 5 and 9.
        for width in (1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 15, 16, 17, 31, 32, 33):
            for transparent in (False, True):
                data, expected = palette_png(width, transparent)
                for tool, args in (("pngquant", ["--nofs", "256", "-"]), ("posterize", ["255"])):
                    with self.subTest(width=width, trns=transparent, tool=tool):
                        image = self.convert(tool, args, data)
                        self.assertEqual(image.size, (width, 3))
                        self.assertEqual(list(image.getdata()), expected)

    def test_app_quality_dither_and_blur_modes(self):
        data, _ = palette_png(17, True)
        for tool, args in (
            ("pngquant", ["--quality=0-80", "256", "-"]),
            ("pngquant", ["16", "-"]),
            ("posterize", ["-Q", "80"]),
            ("posterize", ["-d", "16"]),
            ("posterize", ["-b", "16"]),
        ):
            with self.subTest(tool=tool, args=args):
                image = self.convert(tool, args, data)
                self.assertEqual(image.size, (17, 3))
                self.assertGreater(len(set(image.getdata())), 1)
                self.assertLess(min(image.getchannel("A").getdata()), 255)

    def test_rejects_truncated_input_without_signal(self):
        data, _ = palette_png(9, True)
        for tool, args in (("pngquant", ["256", "-"]), ("posterize", ["255"])):
            with self.subTest(tool=tool):
                result = subprocess.run([str(TOOLS / tool), *args], input=data[:50], capture_output=True, timeout=30)
                self.assertGreater(result.returncode, 0, result.stderr)
                self.assertFalse(result.stdout.startswith(b"\x89PNG"))


if __name__ == "__main__":
    unittest.main()
