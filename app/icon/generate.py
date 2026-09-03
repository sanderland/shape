"""Generates the launcher icon: a board, a local shape, and the move that completes it.
Run with any Python that has Pillow, then `dart run flutter_launcher_icons`."""

from pathlib import Path

from PIL import Image, ImageDraw

S = 1024
BOARD = (216, 186, 146)
LINE = (138, 106, 68)
BLACK = (26, 26, 26)
WHITE = (250, 250, 248)
GREEN = (11, 110, 46)
GREEN_HI = (34, 160, 74)

# 5 lines each way; the three inner intersections sit inside the adaptive-icon
# safe zone (the middle 66%), so nothing that matters can be masked away.
STEP = S / 5
P = [round(STEP * (i + 0.5)) for i in range(5)]
R = round(STEP * 0.44)


def grid(d):
    # Bled to the edges rather than stopped at the outermost line: a mask crops the
    # icon, and visible line-ends would read as a floating sheet of graph paper.
    w = max(5, round(S * 0.0085))
    for c in P:
        d.line([(c, -w), (c, S + w)], fill=LINE, width=w)
        d.line([(-w, c), (S + w, c)], fill=LINE, width=w)
    # Star point, so it reads as a board rather than graph paper.
    d.ellipse([P[2] - w * 2.0, P[2] - w * 2.0, P[2] + w * 2.0, P[2] + w * 2.0], fill=LINE)


def stone(d, cx, cy, color):
    d.ellipse([cx - R, cy - R, cx + R, cy + R], fill=color)


def marker(d, cx, cy):
    """The green policy square the app paints on a suggested move."""
    h = round(R * 0.95)
    d.rounded_rectangle([cx - h, cy - h, cx + h, cy + h], radius=round(h * 0.26), fill=GREEN)


def draw(img):
    d = ImageDraw.Draw(img)
    grid(d)
    # Everything meaningful stays on the three inner intersections, which are the
    # only ones inside the safe zone.
    stone(d, P[1], P[2], BLACK)
    stone(d, P[2], P[3], BLACK)
    stone(d, P[3], P[2], WHITE)
    marker(d, P[2], P[2])
    return img


out = Path(__file__).parent
draw(Image.new("RGBA", (S, S), (0, 0, 0, 0))).save(out / "foreground.png")
draw(Image.new("RGBA", (S, S), BOARD)).save(out / "icon.png")
print("written")
