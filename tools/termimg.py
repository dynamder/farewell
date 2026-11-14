"""terminal frame renderer + resolution-ladder demo.

Two jobs:
  ansi2png <frame.txt> <out.png>     render a captured ANSI frame
  ladder  <outdir>                   render one subject in 6 blitter modes
"""
import re
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

CW, CH = 10, 20  # cell size in px
FONT = ImageFont.truetype("C:/Windows/Fonts/CascadiaMono.ttf", 16)

# --- glyph geometry: which sub-cells a block char inks -------------------
BLOCKS = {
    "█": [(0, 0, 1, 1)],
    "▀": [(0, 0, 1, 0.5)], "▄": [(0, 0.5, 1, 1)],
    "▌": [(0, 0, 0.5, 1)], "▐": [(0.5, 0, 1, 1)],
    "▖": [(0, 0.5, 0.5, 1)], "▗": [(0.5, 0.5, 1, 1)],
    "▘": [(0, 0, 0.5, 0.5)], "▝": [(0.5, 0, 1, 0.5)],
    "▚": [(0, 0, 0.5, 0.5), (0.5, 0.5, 1, 1)],
    "▞": [(0.5, 0, 1, 0.5), (0, 0.5, 0.5, 1)],
    "▛": [(0, 0, 0.5, 1), (0.5, 0, 1, 0.5)],
    "▜": [(0, 0, 1, 0.5), (0.5, 0.5, 1, 1)],
    "▟": [(0, 0.5, 1, 1), (0.5, 0, 1, 0.5)],
    "▙": [(0, 0, 1, 0.5), (0, 0.5, 0.5, 1)],
    "▁": [(0, 0.85, 1, 1)], "▂": [(0, 0.7, 1, 1)], "▃": [(0, 0.55, 1, 1)],
    "▄": [(0, 0.5, 1, 1)], "▅": [(0, 0.35, 1, 1)], "▆": [(0, 0.2, 1, 1)],
    "▇": [(0, 0.1, 1, 1)], "▉": [(0, 0, 0.85, 1)],
}
BRAILLE = chr(0x2800)
SEXTANT = chr(0x1FB00)

def sextant_cells(ch):
    """U+1FB00..U+1FB3B -> list of (fx, fy) 2x3 sub-blocks."""
    n = ord(ch) - 0x1FB00 + 1
    if n < 1 or n > 0x3F:
        return None
    out = []
    for bit in range(6):
        if n >> bit & 1:
            col, row = bit // 3, bit % 3
            out.append((col, row))
    return out

def braille_cells(ch):
    n = ord(ch) - 0x2800
    if n < 0 or n > 0xFF:
        return None
    out = []
    pos = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]
    for bit, (cx, cy) in enumerate(pos):
        if n >> bit & 1:
            out.append((cx, cy))
    return out

# --- ANSI subset parser ---------------------------------------------------
CSI = re.compile(rb"\x1b\[([0-9;?]*)([A-Za-z])")

class Grid:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.ch = [[" "] * w for _ in range(h)]
        self.fg = [[None] * w for _ in range(h)]
        self.bg = [[None] * w for _ in range(h)]

def parse_ansi(data, w, h):
    g = Grid(w, h)
    fg = bg = None
    x = y = 0
    i = 0
    while i < len(data):
        if data[i] == 0x1B and i + 1 < len(data):
            m = CSI.match(data, i)
            if m:
                params, final = m.group(1).decode(), m.group(2).decode()
                nums = [int(p) if p.isdigit() else 0 for p in params.replace("?", "").split(";")]
                if final == "H":
                    y = (nums[0] if nums else 1) - 1
                    x = (nums[1] if len(nums) > 1 else 1) - 1
                elif final == "m":
                    j = 0
                    while j < len(nums):
                        v = nums[j]
                        if v == 0:
                            fg = bg = None
                        elif v == 38 and nums[j + 1] == 2:
                            fg = tuple(nums[j + 2:j + 5]); j += 4
                        elif v == 48 and nums[j + 1] == 2:
                            bg = tuple(nums[j + 2:j + 5]); j += 4
                        elif v == 38 and nums[j + 1] == 5:
                            fg = xterm(nums[j + 2]); j += 2
                        elif v == 48 and nums[j + 1] == 5:
                            bg = xterm(nums[j + 2]); j += 2
                        j += 1
                i = m.end()
                continue
            i += 2
            continue
        if data[i] == 0x0A:
            y += 1; x = 0; i += 1; continue
        if data[i] == 0x0D:
            x = 0; i += 1; continue
        # decode one utf-8 char
        for ln in (1, 2, 3, 4):
            try:
                ch = data[i:i + ln].decode("utf8"); break
            except UnicodeDecodeError:
                ch = None
        if ch is None:
            i += 1; continue
        if 0 <= y < h and 0 <= x < w:
            g.ch[y][x] = ch; g.fg[y][x] = fg; g.bg[y][x] = bg
        x += 1
        i += ln
    return g

def xterm(n):
    if n < 16:
        base = [(0,0,0),(128,0,0),(0,128,0),(128,128,0),(0,0,128),(128,0,128),(0,128,128),(192,192,192),
                (128,128,128),(255,0,0),(0,255,0),(255,255,0),(0,0,255),(255,0,255),(0,255,255),(255,255,255)]
        return base[n]
    if n < 232:
        n -= 16
        r, g, b = n // 36, (n % 36) // 6, n % 6
        f = lambda v: 0 if v == 0 else 55 + v * 40
        return (f(r), f(g), f(b))
    v = 8 + (n - 232) * 10
    return (v, v, v)

def draw_grid(g, scale=1):
    img = Image.new("RGB", (g.w * CW, g.h * CH), (12, 12, 16))
    d = ImageDraw.Draw(img)
    for yy in range(g.h):
        for xx in range(g.w):
            ch, fg, bg = g.ch[yy][xx], g.fg[yy][xx], g.bg[yy][xx]
            x0, y0 = xx * CW, yy * CH
            if bg:
                d.rectangle([x0, y0, x0 + CW - 1, y0 + CH - 1], fill=bg)
            if ch == " ":
                continue
            col = fg or (220, 220, 220)
            rects = BLOCKS.get(ch)
            if rects is None:
                sq = sextant_cells(ch)
                if sq is not None:
                    rects = [(cx / 2, cy / 3, (cx + 1) / 2, (cy + 1) / 3) for cx, cy in sq]
            if rects is not None:
                for fx0, fy0, fx1, fy1 in rects:
                    d.rectangle([x0 + fx0 * CW, y0 + fy0 * CH,
                                 x0 + fx1 * CW - 1, y0 + fy1 * CH - 1], fill=col)
                continue
            dots = braille_cells(ch)
            if dots is not None:
                for cx, cy in dots:
                    px = x0 + (cx + 0.5) * CW / 2
                    py = y0 + (cy + 0.5) * CH / 4
                    r = min(CW / 2, CH / 4) * 0.42
                    d.ellipse([px - r, py - r, px + r, py + r], fill=col)
                continue
            d.text((x0, y0 - 1), ch, font=FONT, fill=col)
    return img

# --- resolution ladder ----------------------------------------------------
def subject(w, h):
    """analytic shaded sphere, returns float32 (h,w,3) in 0..1"""
    ys, xs = np.mgrid[0:h, 0:w]
    X = (xs + 0.5) / w * 2 - 1
    Y = ((ys + 0.5) / h * 2 - 1) * (h / w)
    R = 0.72
    d2 = X * X + Y * Y
    inside = d2 < R * R
    Z = np.sqrt(np.clip(R * R - d2, 0, None))
    nx, ny, nz = X / R, Y / R, Z / R
    L = np.array([-0.35, -0.5, 0.79]); L /= np.linalg.norm(L)
    lam = np.clip(nx * L[0] + ny * L[1] + nz * L[2], 0, 1)
    V = np.array([0.0, 0.0, 1.0])
    Hh = L + V; Hh /= np.linalg.norm(Hh)
    spec = np.clip(nx * Hh[0] + ny * Hh[1] + nz * Hh[2], 0, 1) ** 48
    rim = (1 - nz) ** 3
    base = np.array([0.10, 0.62, 0.95])
    col = (base * (0.12 + 0.88 * lam)[..., None]
           + 0.95 * spec[..., None] * np.array([1.0, 0.98, 0.90])
           + 0.35 * rim[..., None] * np.array([0.25, 0.55, 1.0]))
    # background: vertical gradient
    g = np.linspace(0.05, 0.16, h)[:, None, None] * np.array([0.6, 0.8, 1.0])
    out = np.where(inside[..., None], col, g)
    return np.clip(out, 0, 1)

RAMP = " .:-=+*#%@"

def ladder(outdir, cw=96, chh=28, sub=8):
    W, H = cw * sub, chh * sub
    img = subject(W, H)
    lum = img @ np.array([0.2126, 0.7152, 0.0722])
    results = {}

    def cell_avg(arr, fy0, fy1, fx0, fx1):
        return arr[fy0:fy1, fx0:fx1].mean(axis=(0, 1))

    modes = ["ascii", "half", "quad", "sextant", "octant", "braille"]
    for mode in modes:
        g = Grid(cw, chh)
        for ry in range(chh):
            for rx in range(cw):
                y0, y1 = ry * sub, (ry + 1) * sub
                x0, x1 = rx * sub, (rx + 1) * sub
                if mode == "ascii":
                    v = lum[y0:y1, x0:x1].mean()
                    g.ch[ry][rx] = RAMP[min(len(RAMP) - 1, int(v * len(RAMP)))]
                    c = cell_avg(img, y0, y1, x0, x1)
                    g.fg[ry][rx] = tuple(int(v * 255) for v in c)
                elif mode == "half":
                    top = cell_avg(img, y0, (y0 + y1) // 2, x0, x1)
                    bot = cell_avg(img, (y0 + y1) // 2, y1, x0, x1)
                    g.ch[ry][rx] = "▀"
                    g.fg[ry][rx] = tuple(int(v * 255) for v in top)
                    g.bg[ry][rx] = tuple(int(v * 255) for v in bot)
                elif mode == "quad":
                    q = [(y0, (y0 + y1) // 2, x0, (x0 + x1) // 2),
                         (y0, (y0 + y1) // 2, (x0 + x1) // 2, x1),
                         ((y0 + y1) // 2, y1, x0, (x0 + x1) // 2),
                         ((y0 + y1) // 2, y1, (x0 + x1) // 2, x1)]
                    cols = [cell_avg(img, *c) for c in q]
                    # pick the two dominant colours: top-left vs rest approximation
                    g.ch[ry][rx] = "▚"
                    g.fg[ry][rx] = tuple(int(v * 255) for v in cols[0])
                    g.bg[ry][rx] = tuple(int(v * 255) for v in cols[3])
                elif mode in ("sextant", "octant"):
                    ny, nx = (3, 2) if mode == "sextant" else (4, 2)
                    cols = []
                    for cy in range(ny):
                        for cx in range(nx):
                            yy0 = y0 + (y1 - y0) * cy // ny
                            yy1 = y0 + (y1 - y0) * (cy + 1) // ny
                            xx0 = x0 + (x1 - x0) * cx // nx
                            xx1 = x0 + (x1 - x0) * (cx + 1) // nx
                            cols.append(cell_avg(img, yy0, yy1, xx0, xx1))
                    # two-colour split: brightest vs darkest cell
                    l = [c @ np.array([0.2126, 0.7152, 0.0722]) for c in cols]
                    hi = int(np.argmax(l)); lo = int(np.argmin(l))
                    thr = (l[hi] + l[lo]) / 2
                    if mode == "sextant":
                        mask = 0
                        for i, v in enumerate(l):
                            if v >= thr:
                                mask |= 1 << i
                        ch_ = chr(0x1FB00 + mask - 1) if mask else " "
                        g.ch[ry][rx] = ch_
                    else:
                        # octants live in U+1CD00 block; fall back to quadrants
                        g.ch[ry][rx] = "█" if l[hi] > 0.5 else " "
                    g.fg[ry][rx] = tuple(int(v * 255) for v in cols[hi])
                    g.bg[ry][rx] = tuple(int(v * 255) for v in cols[lo])
                elif mode == "braille":
                    mask = 0
                    pos = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]
                    for bit, (cx, cy) in enumerate(pos):
                        yy0 = y0 + (y1 - y0) * cy // 4
                        yy1 = y0 + (y1 - y0) * (cy + 1) // 4
                        xx0 = x0 + (x1 - x0) * cx // 2
                        xx1 = x0 + (x1 - x0) * (cx + 1) // 2
                        if lum[yy0:yy1, xx0:xx1].mean() > 0.22:
                            mask |= 1 << bit
                    g.ch[ry][rx] = chr(0x2800 + mask)
                    c = cell_avg(img, y0, y1, x0, x1)
                    g.fg[ry][rx] = tuple(int(v * 255) for v in c)
        im = draw_grid(g)
        im.save(f"{outdir}/ladder_{mode}.png")
        results[mode] = im
    return results

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "ansi2png":
        data = open(sys.argv[2], "rb").read()
        w, h = int(sys.argv[4]), int(sys.argv[5])
        draw_grid(parse_ansi(data, w, h)).save(sys.argv[3])
        print("wrote", sys.argv[3])
    elif cmd == "ladder":
        ladder(sys.argv[2])
        print("wrote ladder images")
