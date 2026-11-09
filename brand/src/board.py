"""Cuts a screenshot of the whole brand book into its pages, then writes them as a PDF and tiles them into the
overview at the top of brand/README.md.
Run: python3 brand/src/board.py <book.png> brand/board.jpg brand/wick-brand-book.pdf

The book is brand/book/index.html, one 1920 by 1080 page after another. render.sh takes the screenshot.
The PDF is made of pictures of the pages, which keeps it a quarter of the size Chrome's own PDF comes out at.
"""
import sys

from PIL import Image

book = Image.open(sys.argv[1]).convert("RGB")
PAGE = (1920, 1080)
pages = [book.crop((0, top, PAGE[0], top + PAGE[1])) for top in range(0, book.height - PAGE[1] + 1, PAGE[1])]

COLUMNS, GAP, SCALE = 3, 24, 0.5
width, height = int(PAGE[0] * SCALE), int(PAGE[1] * SCALE)
rows = -(-len(pages) // COLUMNS)
board = Image.new("RGB", (COLUMNS * width + (COLUMNS + 1) * GAP, rows * height + (rows + 1) * GAP), "#0C0A09")
for index, page in enumerate(pages):
    x = GAP + (index % COLUMNS) * (width + GAP)
    y = GAP + (index // COLUMNS) * (height + GAP)
    board.paste(page.resize((width, height), Image.LANCZOS), (x, y))
board.save(sys.argv[2], quality=88, optimize=True)

pages[0].save(sys.argv[3], save_all=True, append_images=pages[1:], quality=90, resolution=144)
print(len(pages), "pages", board.size)
