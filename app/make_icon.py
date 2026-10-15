"""Draws the app icon: a dark sensor grid with one hot pixel being fixed."""
import os, subprocess, sys
from PIL import Image, ImageDraw, ImageFilter

def draw(size):
    s = size / 1024
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([100*s, 100*s, 924*s, 924*s], radius=185*s, fill=(28, 30, 38, 255))
    n, pad = 6, 190*s
    cell = (size - 2*pad) / n
    colors = [[(150, 40, 40), (40, 120, 50)], [(40, 120, 50), (40, 60, 160)]]
    for r in range(n):
        for c in range(n):
            x, y = pad + c*cell, pad + r*cell
            col = colors[r % 2][c % 2]
            d.rounded_rectangle([x+6*s, y+6*s, x+cell-6*s, y+cell-6*s], radius=12*s, fill=col + (255,))
    # the hot pixel
    hr, hc = 2, 3
    x, y = pad + hc*cell, pad + hr*cell
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([x-40*s, y-40*s, x+cell+40*s, y+cell+40*s], fill=(255, 210, 120, 200))
    img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(30*s)))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([x+6*s, y+6*s, x+cell-6*s, y+cell-6*s], radius=12*s, fill=(255, 250, 235, 255))
    # sparkle / wand stroke
    d.line([x+cell*0.5, y+cell*0.5, 860*s, 860*s], fill=(255, 255, 255, 230), width=int(34*s))
    return img

out = sys.argv[1]
iconset = out.replace(".icns", ".iconset")
os.makedirs(iconset, exist_ok=True)
for base in (16, 32, 128, 256, 512):
    draw(base).save(f"{iconset}/icon_{base}x{base}.png")
    draw(base*2).save(f"{iconset}/icon_{base}x{base}@2x.png")
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
