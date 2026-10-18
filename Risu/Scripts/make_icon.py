#!/usr/bin/env python3
"""Draw Risu's app icon — a pixel-art squirrel — and fill the asset catalog.

    Scripts/make_icon.py [--preview]

The art is the SPRITE grid below, one character per pixel. That's the source:
edit the grid, run this, and every size is redrawn. A 1024x1024 PNG checked in
with no way to change it would be a dead end the first time we wanted the tail
a pixel longer.

Sizes that are whole multiples of the grid scale with nearest-neighbour, so a
pixel stays a hard-edged square. The small Mac sizes can't — 32 pixels don't
fit in 16 — so those average instead, which reads better than dropping every
other row.

No third-party imaging: PNG is a header, a zlib stream and a CRC, and Pillow
isn't installed on this Mac (nothing gets installed here without asking).
"""

import argparse
import json
import pathlib
import struct
import sys
import zlib

# ---------------------------------------------------------------- the drawing

# A squirrel sitting in profile, facing left, holding an acorn — a squirrel
# putting something by for later being the whole idea of the app. 32x32,
# because an icon has to survive being 16 pixels wide in a Dock.
SPRITE = [
    "................................",
    "................................",
    ".................OOOOO..........",
    ".......OO......OOMMMMMOO........",
    "......OMMO....OMMLLLLLMMO.......",
    "......OMLO...OMMLLLLLLLMMO......",
    "......OMLO...OMLLLLLLLLLMMO.....",
    ".....OOMLOO.OMMLLLLLLLLLLMMO....",
    "....OMMMLMMOOMMLLLLLLLLLLLMMO...",
    "...OMLLLLLLMOMMLLLLLLLLLLLLMMO..",
    "...OMLLLLLLLMMMLLLLLLLLLLLLLMO..",
    "..OMLLEELLLLLMMLLLLLLLLLLLLLMO..",
    "..OMLLEWLLLLLMMLLLLLLLLLLLLLMO..",
    "..OMLLLLLLLLLMMMLLLLLLLLLLLLMO..",
    "..ONMLCLLLLLLMMMLLLLLLLLLLLMMO..",
    "..OONMCCLLLLLMMMMLLLLLLLLLLMMO..",
    "....OMCCCCCCLMMMMMLLLLLLLLLMMO..",
    "....OMCCBBBBCCMMMMMLLLLLLLMMMO..",
    "....OCCBBBBBBCCMMMMMMLLLLMMMO...",
    "....OCCBAAAAABCCMMMMMMMMMMMO....",
    "....OCCCAAAAACCCMMMMMMMMMMO.....",
    "....OCCCCAAACCCCMMMMMMMMOO......",
    "....OMCCCCACCCCCMMMMMMOO........",
    "....OMMCCCCCCCCMMMMMOO..........",
    "...OMMMMCCCCCMMMMMMOO...........",
    "...OMMMMMMMMMMMMMMMO............",
    "...OMMMOOOOOOOMMMMMO............",
    "...OMMO......OMMMMMO............",
    "....OOO......OOOOOOO............",
    "................................",
    "................................",
    "................................",
]

PALETTE = {
    ".": None,                  # background shows through
    "O": (0x3A, 0x22, 0x14),    # outline, a brown dark enough to read as black
    "D": (0x8A, 0x43, 0x1B),    # shadowed fur
    "M": (0xC2, 0x63, 0x28),    # fur
    "L": (0xE3, 0x8E, 0x3F),    # lit fur
    "C": (0xF5, 0xDC, 0xB4),    # chest and cheek
    "E": (0x2A, 0x19, 0x0E),    # eye
    "W": (0xFF, 0xFF, 0xFF),    # the glint, which is what makes it look alive
    "A": (0xD9, 0xA8, 0x5E),    # acorn
    "B": (0x6E, 0x44, 0x24),    # acorn cap
    "N": (0x2A, 0x19, 0x0E),    # nose
}

# Deep green: the fur is orange, and orange on green is the loudest an icon
# gets without shouting. Also what a squirrel is usually in front of.
BACKGROUND = (0x24, 0x54, 0x43)

GRID = 32


def sprite_pixels():
    """The grid as [row][col] -> (r, g, b) or None, with the art checked."""
    if len(SPRITE) != GRID:
        sys.exit(f"sprite is {len(SPRITE)} rows, expected {GRID}")
    grid = []
    for y, row in enumerate(SPRITE):
        if len(row) != GRID:
            sys.exit(f"row {y} is {len(row)} characters, expected {GRID}")
        out = []
        for x, char in enumerate(row):
            if char not in PALETTE:
                sys.exit(f"row {y}, column {x}: no colour for {char!r}")
            out.append(PALETTE[char])
        grid.append(out)
    return grid


# ------------------------------------------------------------------ rendering

def rounded_mask(size, radius):
    """Which pixels are inside a rounded square — the Mac draws its own
    corners, unlike iOS, which masks the icon for you."""
    mask = [[True] * size for _ in range(size)]
    for y in range(size):
        for x in range(size):
            dx = min(x, size - 1 - x)
            dy = min(y, size - 1 - y)
            if dx < radius and dy < radius:
                ox, oy = radius - dx, radius - dy
                mask[y][x] = ox * ox + oy * oy <= radius * radius
    return mask


def render(size, inset=0.0, rounded=False, margin=None):
    """One icon, as rows of RGBA bytes.

    `inset` is the fraction of the canvas left empty around the art, which is
    how a Mac icon sits in its grid; iOS art runs to the edge and gets masked.
    `margin` is the breathing room inside the plate, in plate pixels — pass 0
    for the small sizes, which need every pixel they can get more than they
    need air around the squirrel.
    """
    grid = sprite_pixels()
    plate = int(round(size * (1 - 2 * inset)))
    origin = (size - plate) // 2
    mask = rounded_mask(plate, int(round(plate * 0.225))) if rounded else None

    # The art is drawn in the plate, a little in from its edges so the squirrel
    # isn't touching the corners.
    if margin is None:
        margin = max(1, plate // 32)
    art = plate - 2 * margin
    transparent = bytes((0, 0, 0, 0))

    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            px, py = x - origin, y - origin
            if not (0 <= px < plate and 0 <= py < plate):
                row += transparent
                continue
            if mask is not None and not mask[py][px]:
                row += transparent
                continue
            colour = BACKGROUND
            ax, ay = px - margin, py - margin
            if 0 <= ax < art and 0 <= ay < art:
                # Nearest-neighbour: at sizes that divide by 32 this is exact,
                # and at the odd ones it keeps the edges hard.
                sx = min(GRID - 1, ax * GRID // art)
                sy = min(GRID - 1, ay * GRID // art)
                if grid[sy][sx] is not None:
                    colour = grid[sy][sx]
            row += bytes(colour) + b"\xff"
        rows.append(bytes(row))
    return rows


def downsample(rows, size, target):
    """Average down. Only for the sizes too small to hold the grid, where
    nearest-neighbour would drop whole features — an ear, or the eye."""
    factor = size // target
    out = []
    for ty in range(target):
        row = bytearray()
        for tx in range(target):
            r = g = b = a = 0
            for dy in range(factor):
                source = rows[ty * factor + dy]
                for dx in range(factor):
                    i = (tx * factor + dx) * 4
                    alpha = source[i + 3]
                    r += source[i] * alpha
                    g += source[i + 1] * alpha
                    b += source[i + 2] * alpha
                    a += alpha
            n = factor * factor
            if a == 0:
                row += bytes((0, 0, 0, 0))
            else:
                row += bytes((r // a, g // a, b // a, a // n))
        out.append(bytes(row))
    return out


def write_png(path, rows):
    width = len(rows[0]) // 4
    height = len(rows)
    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    path.write_bytes(png)


# -------------------------------------------------------------------- catalog

# iOS takes the one 1024 and masks it itself.


def build(root):
    icons = root / "Risu" / "Assets.xcassets" / "AppIcon.appiconset"
    icons.mkdir(parents=True, exist_ok=True)

    write_png(icons / "icon-ios-1024.png", render(1024))
    images = [{"idiom": "universal", "platform": "ios",
               "size": "1024x1024", "filename": "icon-ios-1024.png"}]

    (icons / "Contents.json").write_text(json.dumps(
        {"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

    catalog = root / "Risu" / "Assets.xcassets" / "Contents.json"
    catalog.write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print(f"wrote {len(images)} images to {icons}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview", metavar="PATH",
                        help="write one big PNG to look at, and change nothing else")
    args = parser.parse_args()

    if args.preview:
        write_png(pathlib.Path(args.preview), render(512))
        print(f"wrote {args.preview}")
        return
    build(pathlib.Path(__file__).resolve().parent.parent)


if __name__ == "__main__":
    main()
