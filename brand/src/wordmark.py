"""Writes the other versions of the Wick wordmark from the one that's already set, so the word is never retyped.
Run: python3 brand/src/wordmark.py brand/logo

Reads wordmark-light.svg, which lockup.py outlined from Geist Medium. When the word stands alone, the ember moves
to the i: its square tittle becomes a circle of the same area. There's only ever one ember in a composition, so
the lockups, where the mark already has it, keep the plain word.
"""
import math
import re
import sys
from pathlib import Path

out = Path(sys.argv[1])
source = (out / "wordmark-light.svg").read_text()
path = re.search(r' d="([^"]+)"', source).group(1)
_, _, width, height = (float(n) for n in re.search(r'viewBox="([^"]+)"', source).group(1).split())


def corners(outline):
    """The bounding box of an outline made only of straight horizontal and vertical moves, or None."""
    if re.sub(r"[-\d. ]", "", outline).strip("MHVZ"):
        return None
    x = y = 0.0
    xs, ys = [], []
    for command, numbers in re.findall(r"([MHV])([-\d. ]+)", outline):
        values = [float(n) for n in numbers.split()]
        if command == "M":
            x, y = values
        elif command == "H":
            x = values[0]
        else:
            y = values[0]
        xs.append(x)
        ys.append(y)
    return min(xs), min(ys), max(xs), max(ys)


outlines = [part + "Z" for part in path.split("Z") if part.strip()]
# The tittle is the rectangle that starts at the cap line and stops well short of the baseline. The stem is taller.
boxes = [(index, corners(outline)) for index, outline in enumerate(outlines)]
tittles = [(index, box) for index, box in boxes if box and box[1] < 1 and box[3] - box[1] < height / 4]
if len(tittles) != 1:
    raise SystemExit("Couldn't find the tittle of the i. Has the wordmark changed?")
index, (left, top, right, bottom) = tittles[0]
letters = "".join(outline for position, outline in enumerate(outlines) if position != index)
cx, cy = (left + right) / 2, (top + bottom) / 2
radius = (right - left) / math.sqrt(math.pi)
lift = cy - radius - 2


def write(name, ink, ember=None):
    if ember is None:
        body, box = f'<path d="{path}" fill="{ink}"/>', f"0 0 {width:g} {height:g}"
    else:
        body = f'<path d="{letters}" fill="{ink}"/><circle cx="{cx:.1f}" cy="{cy:.1f}" r="{radius:.1f}" fill="{ember}"/>'
        # Room for the circle above the cap line and for the c's overshoot below the baseline.
        box = f"0 {lift:.1f} {width:g} {height - lift + 6:.1f}"
    (out / f"{name}.svg").write_text(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{box}">{body}</svg>\n')
    print(name, box)


write("wordmark-dark", "#141211")
write("wordmark-ember-light", "#F5F2EE", "#FF8A3D")
write("wordmark-ember-dark", "#141211", "#FF8A3D")
