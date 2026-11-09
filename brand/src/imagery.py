"""Turns stills captured from the website's laptop into the brand's imagery.
Run: python3 brand/src/imagery.py <captures dir> brand/imagery site/public

The captures come from the site itself: open it with ?capture in a dev server and call wickCapture(), which is in
site/src/main.ts. The glow in a capture runs to the edge of the frame and stops dead there, so each picture's edges
are feathered here, and it can then sit on any background of its own tone.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

captures, imagery, site = (Path(arg) for arg in sys.argv[1:4])


def feathered(image, band_x=0.14, band_y=0.2):
    pixels = np.asarray(image.convert("RGBA")).astype(np.float32)
    height, width = pixels.shape[:2]

    def fade(length, band):
        # 0 at the very edge, 1 once a band's width in from it, with an eased step between.
        distance = 1 - np.abs(np.linspace(-1, 1, length))
        t = np.clip(distance / band, 0, 1)
        return t * t * (3 - 2 * t)

    pixels[..., 3] *= np.outer(fade(height, band_y), fade(width, band_x))
    return Image.fromarray(pixels.round().astype(np.uint8))


for source in sorted(captures.glob("laptop-*.png")):
    picture = feathered(Image.open(source))
    picture.save(imagery / f"{source.stem}.webp", quality=88, method=6)
    print(source.stem, picture.size)

# The website shows two of them when motion is reduced or WebGL is missing.
for name, size in (("laptop-open", (1600, 1133)), ("laptop-rest", (1600, 900))):
    still = Image.open(imagery / f"{name}.webp").resize(size, Image.LANCZOS)
    still.save(site / f"{'laptop-closed' if name == 'laptop-rest' else name}.webp", quality=86, method=6)
