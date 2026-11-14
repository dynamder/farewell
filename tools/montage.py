import sys
from PIL import Image, ImageDraw, ImageFont
F = ImageFont.truetype("C:/Windows/Fonts/CascadiaMono.ttf", 22)
items = [("ascii 1x1 chars", "demos/ladder_ascii.png"),
         ("half block 1x2", "demos/ladder_half.png"),
         ("quadrant 2x2", "demos/ladder_quad.png"),
         ("sextant 2x3", "demos/ladder_sextant.png"),
         ("braille 2x4 dots", "demos/ladder_braille.png")]
W = 760; BAR = 34
tiles = []
for label, path in items:
    im = Image.open(path).convert("RGB")
    h = int(im.height * W / im.width)
    tiles.append((label, im.resize((W, h), Image.LANCZOS)))
total = sum(t[1].height + BAR for t in tiles)
out = Image.new("RGB", (W, total), (8, 8, 12))
d = ImageDraw.Draw(out)
y = 0
for label, im in tiles:
    d.rectangle([0, y, W, y + BAR - 1], fill=(22, 24, 32))
    d.text((10, y + 6), label, font=F, fill=(150, 200, 255))
    y += BAR
    out.paste(im, (0, y)); y += im.height
out.save("demos/ladder_contact.png")
print("ok", out.size)
