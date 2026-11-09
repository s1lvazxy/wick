#!/bin/sh
# Renders the brand book and the social images from brand/book, with nothing but Chrome and Python.
# Run from the repository root: brand/src/render.sh
set -eu

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
BOOK="file://$PWD/brand/book"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

shot() {
  # shot <width> <height> <url> <file>
  "$CHROME" --headless --hide-scrollbars --default-background-color=00000000 \
    --window-size="$1,$2" --screenshot="$4" "$3" >/dev/null 2>&1
}

PAGES=$(grep -c 'class="page' brand/book/index.html)
shot 1920 $((PAGES * 1080)) "$BOOK/index.html" "$WORK/book.png"
python3 brand/src/board.py "$WORK/book.png" brand/board.jpg brand/wick-brand-book.pdf

shot 1200 630 "$BOOK/social.html#og" brand/social/og.png
shot 1280 640 "$BOOK/social.html#github" brand/social/github.png
shot 1024 1024 "$BOOK/social.html#avatar" brand/social/avatar.png
shot 1720 760 "$BOOK/social.html#readme" docs/hero.png
shot 1472 614 "$BOOK/social.html#panels" docs/panel.png

# The website keeps its own copies, so it builds without the rest of the repository.
cp brand/social/og.png site/public/og.png
python3 - <<'PY'
from PIL import Image
Image.open("brand/social/avatar.png").convert("RGB").resize((180, 180), Image.LANCZOS).save("site/public/apple-touch-icon.png")
PY
echo "Rendered $PAGES pages, and the social images."
