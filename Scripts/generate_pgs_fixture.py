#!/usr/bin/env python3
"""Original SUP fixture. CoreText draws our caption; no third-party media is used."""
import itertools
import struct
import subprocess
from pathlib import Path
import tempfile


def make_pgs(font, canvas_width, canvas_height):
    width, height = min(360, canvas_width), 56
    pixels = subprocess.check_output(['swift', '-module-cache-path', str(Path(tempfile.gettempdir())/'glide-pgs-module-cache'),
                                     str(Path(__file__).with_name('generate_pgs_text.swift')), str(font), str(width), str(height)])
    rle = bytearray()
    for row in range(height):
        indices = [min(15, round(v / 17)) for v in pixels[row * width:(row + 1) * width]]
        for color, values in itertools.groupby(indices):
            count = sum(1 for _ in values)
            if color and count == 1:
                rle.append(color)
            elif count <= 63:
                rle.extend([0, count | (0x80 if color else 0)])
                if color:
                    rle.append(color)
            else:
                rle.extend([0, (count >> 8) | 0x40 | (0x80 if color else 0), count & 255])
                if color:
                    rle.append(color)
        rle.extend([0, 0])
    def packet(kind, body, pts=0):
        return b'PG' + struct.pack('>IIBH', pts, 0, kind, len(body)) + body
    def composition(count, pts=0):
        body = struct.pack('>HHBHBBBB', canvas_width, canvas_height, 0x10, 0, 0x80 if count else 0, 0, 0, count)
        if count:
            body += struct.pack('>HBBHH', 1, 0, 0, (canvas_width - width) // 2, canvas_height - 110)
        return packet(0x16, body, pts)
    palette = bytes([0, 0]) + b''.join(bytes([i, 235, 128, 128, i * 17]) for i in range(16))
    obj = struct.pack('>HBB', 1, 0, 0xc0) + (len(rle) + 4).to_bytes(3, 'big') + struct.pack('>HH', width, height) + rle
    return composition(1) + packet(0x14, palette) + packet(0x15, obj) + packet(0x80, b'') + composition(0, 120 * 90000) + packet(0x80, b'', 120 * 90000)
