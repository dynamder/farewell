"""Resolution ladder: one subject, five sub-cell densities."""
import sys
import numpy as np
import termimg as T

QUAD = {0: " ", 1: "▘", 2: "▝", 3: "▀", 4: "▖", 5: "▌", 6: "▞", 7: "▛",
        8: "▗", 9: "▚", 10: "▐", 11: "▜", 12: "▄", 13: "▙", 14: "▟", 15: "█"}
RAMP = " .:-=+*#%@"


def subject(w, h, aspect):
    ys, xs = np.mgrid[0:h, 0:w]
    X = (xs + 0.5) / w * 2 - 1
    Y = ((ys + 0.5) / h * 2 - 1) * aspect
    R = min(0.78 * aspect, 0.80)
    d2 = X * X + Y * Y
    inside = d2 < R * R
    Z = np.sqrt(np.clip(R * R - d2, 0, None))
    nx, ny, nz = X / R, Y / R, Z / R
    L = np.array([-0.35, -0.5, 0.79]); L /= np.linalg.norm(L)
    lam = np.clip(nx * L[0] + ny * L[1] + nz * L[2], 0, 1)
    Hh = L + np.array([0.0, 0.0, 1.0]); Hh /= np.linalg.norm(Hh)
    spec = np.clip(nx * Hh[0] + ny * Hh[1] + nz * Hh[2], 0, 1) ** 48
    rim = (1 - nz) ** 3
    base = np.array([0.10, 0.62, 0.95])
    col = (base * (0.12 + 0.88 * lam)[..., None]
           + 0.95 * spec[..., None] * np.array([1.0, 0.98, 0.90])
           + 0.35 * rim[..., None] * np.array([0.25, 0.55, 1.0]))
    g = np.linspace(0.04, 0.14, h)[:, None, None] * np.array([0.6, 0.8, 1.0])
    return np.clip(np.where(inside[..., None], col, g), 0, 1)


def two_colour(cols):
    l = [c @ np.array([0.2126, 0.7152, 0.0722]) for c in cols]
    hi, lo = int(np.argmax(l)), int(np.argmin(l))
    thr = (l[hi] + l[lo]) / 2
    mask = 0
    for i, v in enumerate(l):
        if v >= thr:
            mask |= 1 << i
    return mask, cols[hi], cols[lo]


def main(outdir, cw=96, chh=28, sub=8):
    W, H = cw * sub, chh * sub
    asp = (chh * T.CH) / (cw * T.CW)
    img = subject(W, H, asp)
    lum = img @ np.array([0.2126, 0.7152, 0.0722])

    def avg(a, y0, y1, x0, x1):
        return a[y0:y1, x0:x1].mean(axis=(0, 1))

    for mode in ["ascii", "half", "quad", "sextant", "braille"]:
        g = T.Grid(cw, chh)
        for ry in range(chh):
            for rx in range(cw):
                y0, y1 = ry * sub, (ry + 1) * sub
                x0, x1 = rx * sub, (rx + 1) * sub
                ym, xm = (y0 + y1) // 2, (x0 + x1) // 2
                if mode == "ascii":
                    v = lum[y0:y1, x0:x1].mean()
                    g.ch[ry][rx] = RAMP[min(len(RAMP) - 1, int(v * len(RAMP)))]
                    g.fg[ry][rx] = tuple(int(v * 255) for v in avg(img, y0, y1, x0, x1))
                elif mode == "half":
                    g.ch[ry][rx] = "▀"
                    g.fg[ry][rx] = tuple(int(v * 255) for v in avg(img, y0, ym, x0, x1))
                    g.bg[ry][rx] = tuple(int(v * 255) for v in avg(img, ym, y1, x0, x1))
                elif mode == "quad":
                    cols = [avg(img, y0, ym, x0, xm), avg(img, y0, ym, xm, x1),
                            avg(img, ym, y1, x0, xm), avg(img, ym, y1, xm, x1)]
                    m, hi, lo = two_colour(cols)
                    g.ch[ry][rx] = QUAD[m]
                    g.fg[ry][rx] = tuple(int(v * 255) for v in hi)
                    g.bg[ry][rx] = tuple(int(v * 255) for v in lo)
                elif mode == "sextant":
                    cols = [avg(img, y0 + (y1 - y0) * cy // 3, y0 + (y1 - y0) * (cy + 1) // 3,
                                x0 + (x1 - x0) * cx // 2, x0 + (x1 - x0) * (cx + 1) // 2)
                            for cy in range(3) for cx in range(2)]
                    m, hi, lo = two_colour(cols)
                    g.ch[ry][rx] = chr(0x1FB00 + m - 1) if m else " "
                    g.fg[ry][rx] = tuple(int(v * 255) for v in hi)
                    g.bg[ry][rx] = tuple(int(v * 255) for v in lo)
                elif mode == "braille":
                    mask = 0
                    for bit, (cx, cy) in enumerate([(0, 0), (0, 1), (0, 2), (1, 0),
                                                    (1, 1), (1, 2), (0, 3), (1, 3)]):
                        sy, sx = (y1 - y0) // 4, (x1 - x0) // 2
                        patch = lum[y0 + cy * sy:y0 + (cy + 1) * sy,
                                    x0 + cx * sx:x0 + (cx + 1) * sx]
                        if patch.mean() > 0.20:
                            mask |= 1 << bit
                    g.ch[ry][rx] = chr(0x2800 + mask)
                    g.fg[ry][rx] = tuple(int(v * 255) for v in avg(img, y0, y1, x0, x1))
        T.draw_grid(g).save(f"{outdir}/ladder_{mode}.png")
        print("wrote", f"{outdir}/ladder_{mode}.png", flush=True)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "demos")
