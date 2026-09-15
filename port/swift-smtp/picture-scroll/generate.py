#!/usr/bin/env python3
"""Generate original static PNG fixtures; no downloaded or private images."""
import hashlib
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parent
WIDTH, HEIGHT, COUNT = 800, 450, 20


def chunk(name, payload):
    return struct.pack('>I', len(payload)) + name + payload + struct.pack('>I', zlib.crc32(name + payload) & 0xffffffff)


def png(index):
    rows = bytearray()
    for y in range(HEIGHT):
        rows.append(0)
        for x in range(WIDTH):
            # Distinct gradients and tiles supply varied decoded image pixels.
            tile = ((x // 80 + y // 75 + index) % 3) * 35
            rows.extend(((x // 4 + index * 13 + tile) % 256,
                         (y // 2 + index * 19 + tile) % 256,
                         ((x + y) // 6 + index * 31) % 256))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', WIDTH, HEIGHT, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(bytes(rows), 9)) + chunk(b'IEND', b''))


if __name__ == '__main__':
    images = []
    for index in range(COUNT):
        name = f'picture-{index}.png'
        data = png(index)
        (ROOT / name).write_bytes(data)
        images.append({'name': name, 'width': WIDTH, 'height': HEIGHT, 'bytes': len(data),
                       'sha256': hashlib.sha256(data).hexdigest()})
    (ROOT / 'manifest.json').write_text(json.dumps({'decoded_rgba_budget_bytes': WIDTH * HEIGHT * COUNT * 4,
                                                   'images': images}, indent=2) + '\n')
