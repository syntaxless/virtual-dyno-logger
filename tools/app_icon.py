"""Renders the iOS app icon, App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024x1024, opaque).

  python3 tools/app_icon.py            # needs Pillow

It is the Virtual Dyno web app's own home-screen icon (syntaxless/virtual-dyno, tools/icons.py): the dyno chart as 8-bit pixel
art on a 32x32 grid in the green phosphor palette, scaled 32x with nearest-neighbour so every pixel stays square. The logger
adds a red "recording" dot at the top right. The drawing code is copied from the dyno's icons.py; the palette is the dyno's
default (green) theme, written out below so this script needs no browser. Re-run it after changing either.
"""
from pathlib import Path

from PIL import Image

# The dyno's green theme (index.html :root), plus --err for the record dot.
TOK = {"--bg": "#030f08", "--fg": "#46f08a", "--dim": "#1c7a45", "--faint": "#0e3d22", "--halo": "#08240f",
       "--s2": "#ffb938", "--hi": "#d6ffe6", "--err": "#ff6b5e"}
G = 32
BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
OUT = Path(__file__).resolve().parent.parent / "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"


def curves():
    """Torque and power as SVG-style point lists in a 100x100 box (y down), on one scale like the page's chart: RPM runs 2,000 to 7,000
    across the box and power = torque x RPM / 5252, so the two curves cross at 5,252 RPM."""
    box = (20, 25, 80, 75)                      # left, top, right, bottom: corner at 39% from the centre, inside the 40% safe zone of a maskable icon
    def torque(x):                              # builds fast to a peak at 0.34, then falls away
        return 0.22 + 0.78 * (1 - (1 - x / 0.34) ** 2) if x < 0.34 else 1 - 0.34 * ((x - 0.34) / 0.66) ** 1.25
    xs = [i / 60 for i in range(61)]
    peak = 0.96 / max(torque(x) for x in xs)    # the torque peak sits just under the top of the box
    ts = [(x, torque(x) * peak) for x in xs]
    ps = [(x, y * (2000 + 5000 * x) / 5252) for x, y in ts]
    def pts(seq):
        l, t, r, b = box
        return [(l + x * (r - l), b - y * (b - t)) for x, y in seq]
    return pts(ts), pts(ps), box


def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def bresenham(pts):
    """The pixels on the polyline through pts (floats in grid units), one pixel wide."""
    out = []
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        x0, y0, x1, y1 = round(x0), round(y0), round(x1), round(y1)
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
        err = dx + dy
        while True:
            out.append((x0, y0))
            if (x0, y0) == (x1, y1):
                break
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy
    return out


def draw(tok, kind):
    """The icon on its G x G grid, as an RGBA image."""
    P = {k: rgb(v) for k, v in tok.items()}
    amber_dark = tuple(round(a * .6 + b * .4) for a, b in zip(P["--s2"], P["--bg"]))   # the torque line's shaded underside
    img = Image.new("RGBA", (G, G), P["--bg"] + (255,))
    px = img.load()

    def put(x, y, c):
        if 0 <= x < G and 0 <= y < G:
            px[x, y] = (c if isinstance(c, tuple) else P[c]) + (255,)

    # a dithered glow at the top centre (the screen's halo): ordered dither, so only the two palette colors appear
    for y in range(G):
        for x in range(G):
            d = (((x - 15.5) / 16) ** 2 * .8 + ((y + 3) / 14) ** 2) ** .5
            if .75 - d > (BAYER[y % 4][x % 4] + .5) / 16:
                put(x, y, "--halo")

    tpts, ppts, (l, t, r, b) = curves()
    grid = lambda seq: [(x * G / 100, y * G / 100) for x, y in seq]
    L, T, R, B = (round(v * G / 100) for v in (l, t, r, b))
    for x in range(L, R + 1, 2):                                   # dashed grid lines, at the top and the middle of the chart
        put(x, T, "--faint")
        put(x, (T + B) // 2, "--faint")
    for x in range(L, R + 1):                                      # axes
        put(x, B, "--dim")
    for y in range(T - 1, B + 1):
        put(L, y, "--dim")

    def stroke(seq, face, shade):
        """A one-pixel line with a darker pixel under it, which reads as a two-pixel line with a shaded edge."""
        cells = set(bresenham(grid(seq)))
        for (x, y) in cells:
            if (x, y + 1) not in cells:
                put(x, y + 1, shade)
        for (x, y) in cells:
            put(x, y, face)

    stroke(tpts, "--s2", amber_dark)
    stroke(ppts, "--fg", "--dim")

    # the record dot: a 5x5 pixel disc in --err with a one-pixel highlight, top right, clear of the chart's corner
    dot = {(x, y) for x in range(5) for y in range(5) if (x, y) not in ((0, 0), (4, 0), (0, 4), (4, 4))}
    ox, oy = 23, 2
    for x, y in dot:
        put(ox + x, oy + y, "--err")
    put(ox + 1, oy + 1, "--hi")
    return img


def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    img = draw(TOK, "app").resize((G * 32, G * 32), Image.NEAREST).convert("RGB")   # App Store icons must have no alpha
    img.save(OUT, optimize=True)
    print(OUT, img.size)


if __name__ == "__main__":
    main()
