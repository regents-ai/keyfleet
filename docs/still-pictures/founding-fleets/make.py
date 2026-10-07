# /// script
# dependencies = ["pillow"]
# ///
from PIL import Image, ImageDraw

# The flat Regent crown: 5 columns x 3 rows of squares, top row only columns 0, 2, 4.
CELLS = [(0,0),(2,0),(4,0)] + [(c,r) for r in (1,2) for c in range(5)]
FLEETS = {
    "classic":    ("#0F1B3D", "#F2C14E"),  # gold on midnight navy
    "syndicate":  ("#0B3B2C", "#E9F5EE"),  # ivory on deep green
    "accelerant": ("#1C1210", "#FF5A1F"),  # flame orange on ember black
    "cascade":    ("#06263F", "#47D7EC"),  # water cyan on deep blue
}
SIZE, CELL, GAP = 1200, 128, 16
w = 5*CELL + 4*GAP; h = 3*CELL + 2*GAP
ox, oy = (SIZE-w)//2, (SIZE-h)//2 + 20
for name, (bg, fg) in FLEETS.items():
    img = Image.new("RGB", (SIZE, SIZE), bg)
    d = ImageDraw.Draw(img)
    for c, r in CELLS:
        x, y = ox + c*(CELL+GAP), oy + r*(CELL+GAP)
        d.rectangle([x, y, x+CELL-1, y+CELL-1], fill=fg)
    img.save(f"{name}.png", optimize=True)
row = Image.new("RGB", (SIZE*4//3 + 30, SIZE//3), "#FFFFFF")
for i, name in enumerate(FLEETS):
    row.paste(Image.open(f"{name}.png").resize((SIZE//3, SIZE//3)), (i*(SIZE//3+10), 0))
row.save("all-four.png")
