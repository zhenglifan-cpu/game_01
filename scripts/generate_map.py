#!/usr/bin/env python3
"""
赶羊游戏关卡地图 v8 — 30×30 网格
移除：河流、深草、森林地面、土路、木桥、山丘、泥地、小水塘、路标
保留：羊圈、湖泊、松树、圆树、灌木、草丛、草带、花丛、大/小石堆、树桩、篝火、小木堆
"""

from PIL import Image, ImageDraw, ImageFont

COLS, ROWS = 30, 30
CELL = 50
W, H = COLS * CELL, ROWS * CELL
OL = 2

FONT = "/tmp/SourceHanSans.ttf"
fs  = ImageFont.truetype(FONT, 12)
fm  = ImageFont.truetype(FONT, 15)
fl  = ImageFont.truetype(FONT, 19)
fxl = ImageFont.truetype(FONT, 24)

# ============ 颜色 ============
GRASS      = (177, 212, 102)
PEN_IN     = (240, 220, 168)
FENCE      = (148, 108, 38)
FENCE_DK   = (108, 78, 22)
LAKE       = (55, 128, 205)
LAKE_HI    = (85, 158, 225)
PINE_GRN   = (48, 118, 38)
PINE_HI    = (72, 148, 58)
PINE_DK    = (32, 88, 25)
TREE_GRN   = (62, 148, 52)
TREE_HI    = (92, 178, 78)
TREE_DK    = (42, 108, 35)
TRUNK      = (125, 88, 42)
TRUNK_DK   = (95, 65, 30)
ROCK       = (155, 145, 130)
ROCK_HI    = (182, 172, 155)
ROCK_DK    = (118, 108, 95)
GCLUMP     = (58, 138, 48)
GCLUMP_HI  = (82, 162, 68)
BUSH_CLR   = (55, 130, 45)
BUSH_HI    = (78, 158, 65)
BUSH_DK    = (38, 98, 30)
FLOWER_R   = (225, 85, 85)
FLOWER_P   = (195, 115, 195)
FLOWER_Y   = (245, 225, 75)
FLOWER_W   = (240, 240, 235)
FIRE_O     = (238, 162, 48)
FIRE_Y     = (255, 222, 82)
STUMP_CLR  = (140, 100, 55)
STUMP_DK   = (105, 72, 38)
GRIDLN     = (162, 198, 95)
BLK        = (42, 42, 42)
WHT        = (255, 255, 255)

img = Image.new("RGB", (W, H), GRASS)
d = ImageDraw.Draw(img)

# ============ 工具函数 ============
def cr(c, r):
    x = (c-1)*CELL; y = (r-1)*CELL
    return x, y, x+CELL, y+CELL

def ctr(c, r, w=1, h=1):
    return (c-1)*CELL + w*CELL//2, (r-1)*CELL + h*CELL//2

def fc(c, r, color):
    d.rectangle(cr(c,r), fill=color)

def fcs(c, r, w, h, color):
    for dc in range(w):
        for dr in range(h):
            fc(c+dc, r+dr, color)

def label(cx, cy, text, font=fm, fg=BLK):
    bb = font.getbbox(text)
    tw, th = bb[2]-bb[0], bb[3]-bb[1]
    tx, ty = cx-tw//2, cy-th//2-bb[1]
    bg = WHT if fg == BLK else BLK
    for dx in (-1,0,1):
        for dy in (-1,0,1):
            if dx or dy:
                d.text((tx+dx, ty+dy), text, fill=bg, font=font)
    d.text((tx, ty), text, fill=fg, font=font)

def orect(x1,y1,x2,y2, fc_, oc=BLK, w=OL):
    d.rectangle((x1,y1,x2,y2), fill=fc_)
    d.rectangle((x1,y1,x2,y2), outline=oc, width=w)

def oellip(x1,y1,x2,y2, fc_, oc=BLK, w=OL):
    d.ellipse((x1,y1,x2,y2), fill=fc_)
    d.ellipse((x1,y1,x2,y2), outline=oc, width=w)

# ============ 绘制函数 ============
def draw_pine(c, r):
    cx, cy = ctr(c, r, 2, 2)
    R = int(CELL * 0.92)
    orect(cx-5, cy+10, cx+5, cy+R, TRUNK, BLK, 2)
    pts_bot = [(cx-R, cy+8), (cx+R, cy+8), (cx, cy-R+20)]
    pts_mid = [(cx-R+10, cy-5), (cx+R-10, cy-5), (cx, cy-R+8)]
    d.polygon(pts_bot, fill=PINE_GRN, outline=BLK)
    d.polygon(pts_mid, fill=PINE_HI, outline=BLK)
    d.polygon([(cx-R+20, cy-15), (cx+R-20, cy-15), (cx, cy-R)], fill=PINE_GRN, outline=BLK)

def draw_round_tree(c, r):
    cx, cy = ctr(c, r, 2, 2)
    R = int(CELL * 0.92)
    orect(cx-5, cy+10, cx+5, cy+R, TRUNK, BLK, 2)
    oellip(cx-R, cy-R+6, cx+R, cy+12, TREE_GRN, BLK, OL)
    d.ellipse((cx-R+10, cy-R+10, cx-2, cy-2), fill=TREE_HI)
    d.ellipse((cx+4, cy-R+16, cx+R-6, cy+2), fill=TREE_DK)

def draw_bush(c, r):
    cx, cy = ctr(c, r)
    oellip(cx-16, cy-8, cx+4, cy+12, BUSH_CLR, BLK, 2)
    oellip(cx-6, cy-10, cx+16, cy+10, BUSH_HI, BLK, 2)
    d.ellipse((cx-12, cy-5, cx-4, cy+2), fill=BUSH_HI)

def draw_grass(c, r):
    cx, cy = ctr(c, r)
    for dx in [-9, 0, 9]:
        d.polygon([(cx+dx, cy+9), (cx+dx-5, cy-9), (cx+dx+5, cy-9)],
                  fill=GCLUMP, outline=BLK)
        d.polygon([(cx+dx, cy+5), (cx+dx-3, cy-5), (cx+dx+3, cy-5)],
                  fill=GCLUMP_HI)

def draw_grass_strip(c, r):
    cx, cy = ctr(c, r, 2, 1)
    for dx in [-15, -5, 5, 15]:
        d.polygon([(cx+dx, cy+9), (cx+dx-4, cy-8), (cx+dx+4, cy-8)],
                  fill=GCLUMP, outline=BLK)
        d.polygon([(cx+dx, cy+5), (cx+dx-2, cy-4), (cx+dx+2, cy-4)],
                  fill=GCLUMP_HI)

def draw_flowers(c, r, colors=None):
    if colors is None:
        colors = [FLOWER_R, FLOWER_P, FLOWER_Y]
    cx, cy = ctr(c, r)
    for dx in [-7, 0, 7]:
        d.polygon([(cx+dx, cy+8), (cx+dx-3, cy-2), (cx+dx+3, cy-2)],
                  fill=GCLUMP, outline=GCLUMP)
    positions = [(-8, -6), (0, -9), (8, -4), (-4, 2), (6, 4)]
    for i, (dx, dy) in enumerate(positions):
        clr = colors[i % len(colors)]
        d.ellipse((cx+dx-3, cy+dy-3, cx+dx+3, cy+dy+3), fill=clr, outline=BLK, width=1)
        d.ellipse((cx+dx-1, cy+dy-1, cx+dx+1, cy+dy+1), fill=FLOWER_Y)

def draw_rocks_big(c, r):
    cx, cy = ctr(c, r)
    oellip(cx-17, cy-11, cx+3, cy+11, ROCK, BLK, OL)
    oellip(cx-3, cy-7, cx+17, cy+11, ROCK_HI, BLK, 2)
    d.ellipse((cx-13, cy-7, cx-5, cy+2), fill=ROCK_HI)

def draw_rocks_small(c, r):
    cx, cy = ctr(c, r)
    oellip(cx-11, cy-7, cx+5, cy+8, ROCK_HI, BLK, OL)
    oellip(cx-1, cy-3, cx+12, cy+9, ROCK, BLK, 2)

def draw_stump(c, r):
    cx, cy = ctr(c, r)
    oellip(cx-10, cy-5, cx+10, cy+12, STUMP_CLR, BLK, 2)
    oellip(cx-8, cy-8, cx+8, cy+0, STUMP_DK, BLK, 2)
    d.ellipse((cx-4, cy-6, cx+4, cy-1), fill=STUMP_CLR, outline=STUMP_DK, width=1)

def draw_campfire(c, r):
    cx, cy = ctr(c, r)
    oellip(cx-13, cy+5, cx+13, cy+15, TRUNK, BLK, 1)
    d.polygon([(cx, cy-15), (cx-11, cy+7), (cx+11, cy+7)], fill=FIRE_O, outline=BLK)
    d.polygon([(cx, cy-8), (cx-5, cy+3), (cx+5, cy+3)], fill=FIRE_Y)

def draw_logs(c, r):
    cx, cy = ctr(c, r)
    orect(cx-14, cy-2, cx+8, cy+6, TRUNK, BLK, 2)
    orect(cx-10, cy-8, cx+12, cy+0, STUMP_CLR, BLK, 2)
    d.ellipse((cx+5, cy-7, cx+13, cy+1), fill=STUMP_CLR, outline=BLK, width=1)

# =================================================================
# =================== 地图元素布置 ================================
# =================================================================

# --- 1. 羊圈 — 右上角 (5×5) ---
pen_c, pen_r = 24, 1
pen_w, pen_h = 5, 5
fcs(pen_c, pen_r, pen_w, pen_h, PEN_IN)
FW = CELL // 3 + 2
px1 = (pen_c - 1) * CELL
py1 = (pen_r - 1) * CELL
px2 = (pen_c + pen_w - 1) * CELL
py2 = (pen_r + pen_h - 1) * CELL
orect(px1, py1, px2, py1 + FW, FENCE, BLK, OL)
orect(px1, py2 - FW, px2, py2, FENCE, BLK, OL)
orect(px2 - FW, py1, px2, py2, FENCE, BLK, OL)
orect(px1, py1, px1 + FW, 2 * CELL, FENCE, BLK, OL)
orect(px1, 4 * CELL, px1 + FW, py2, FENCE, BLK, OL)
for c in range(pen_c, pen_c + pen_w):
    cx_ = (c - 1) * CELL + CELL // 2
    d.line([(cx_, py1 + 3), (cx_, py1 + FW - 3)], fill=FENCE_DK, width=2)
    d.line([(cx_, py2 - FW + 3), (cx_, py2 - 3)], fill=FENCE_DK, width=2)
for r in range(pen_r, pen_r + pen_h):
    cy_ = (r - 1) * CELL + CELL // 2
    d.line([(px2 - FW + 3, cy_), (px2 - 3, cy_)], fill=FENCE_DK, width=2)
ay_ = (2 * CELL + 4 * CELL) // 2
d.polygon([(px1 - 10, ay_ - 10), (px1 + 2, ay_), (px1 - 10, ay_ + 10)],
          fill=FENCE, outline=BLK)

# --- 2. 湖泊 — 左下方 (4×3 椭圆) ---
lake_c, lake_r = 4, 21
lake_w, lake_h = 4, 3
for dc in range(lake_w):
    for dr in range(lake_h):
        fc(lake_c + dc, lake_r + dr, LAKE)
lx1 = (lake_c - 1) * CELL + 6
ly1 = (lake_r - 1) * CELL + 6
lx2 = (lake_c + lake_w - 1) * CELL - 6
ly2 = (lake_r + lake_h - 1) * CELL - 6
oellip(lx1, ly1, lx2, ly2, LAKE, BLK, OL)
d.ellipse((lx1 + 15, ly1 + 10, lx1 + 55, ly1 + 28), fill=LAKE_HI)

# --- 3. 松树 ×6 (2×2) ---
pines = [
    (1, 1), (3, 1), (5, 1),
    (1, 4),
    (14, 20), (1, 28),
]
for (pc, pr) in pines:
    draw_pine(pc, pr)

# --- 4. 圆树 ×4 (2×2) ---
round_trees = [
    (22, 1),
    (7, 6),
    (6, 20),
    (27, 27),
]
for (tc, tr) in round_trees:
    draw_round_tree(tc, tr)

# --- 5. 灌木 ×10 (1×1) ---
bushes = [
    (8, 1), (9, 2),
    (7, 5),
    (23, 6), (29, 7),
    (14, 15),
    (1, 15),
    (28, 20),
    (1, 25), (29, 28),
]
for (bc, br) in bushes:
    draw_bush(bc, br)

# --- 6. 草丛 ×10 (1×1) ---
grasses = [
    (5, 8), (9, 5),
    (16, 9), (8, 12),
    (8, 17), (4, 20),
    (15, 22), (20, 24),
    (9, 27), (22, 28),
]
for (gc, gr) in grasses:
    draw_grass(gc, gr)

# --- 7. 草带 ×3 (2×1) ---
grass_strips = [
    (14, 5), (17, 18), (25, 24),
]
for (sc, sr) in grass_strips:
    draw_grass_strip(sc, sr)

# --- 8. 花丛 ×7 (1×1) ---
flowers = [
    (15, 8, [FLOWER_R, FLOWER_P, FLOWER_Y]),
    (17, 6, [FLOWER_W, FLOWER_P, FLOWER_R]),
    (23, 7, [FLOWER_Y, FLOWER_R, FLOWER_P]),
    (14, 14, [FLOWER_R, FLOWER_Y, FLOWER_W]),
    (8, 19, [FLOWER_W, FLOWER_R, FLOWER_P]),
    (26, 25, [FLOWER_R, FLOWER_W, FLOWER_Y]),
    (5, 26, [FLOWER_P, FLOWER_Y, FLOWER_R]),
]
for (fc_, fr_, fcolors) in flowers:
    draw_flowers(fc_, fr_, fcolors)

# --- 9. 大石堆 ×3 (1×1) ---
rocks_big = [(21, 13), (23, 12), (20, 15)]
for (rc, rr) in rocks_big:
    draw_rocks_big(rc, rr)

# --- 10. 小石堆 ×3 (1×1) ---
rocks_small = [(7, 10), (18, 17), (26, 9)]
for (rc, rr) in rocks_small:
    draw_rocks_small(rc, rr)

# --- 11. 树桩 ×2 (1×1) ---
stumps = [(6, 9), (15, 19)]
for (sc, sr) in stumps:
    draw_stump(sc, sr)

# --- 12. 篝火 ×2 (1×1) ---
campfires = [(4, 7), (18, 24)]
for (cc, cr_) in campfires:
    draw_campfire(cc, cr_)

# --- 13. 小木堆 ×2 (1×1) ---
logs = [(5, 6), (26, 19)]
for (lc, lr) in logs:
    draw_logs(lc, lr)

# =================================================================
# 网格线
# =================================================================
for i in range(COLS + 1):
    d.line([(i * CELL, 0), (i * CELL, H)], fill=GRIDLN, width=1)
for i in range(ROWS + 1):
    d.line([(0, i * CELL), (W, i * CELL)], fill=GRIDLN, width=1)

# =================================================================
# 文字标注
# =================================================================
label(*ctr(pen_c, pen_r, pen_w, pen_h), "羊圈", fxl, BLK)
label(*ctr(lake_c, lake_r, lake_w, lake_h), "湖泊", fl, WHT)

for (pc, pr) in pines:
    label(*ctr(pc, pr, 2, 2), "松树", fs, WHT)
for (tc, tr) in round_trees:
    label(*ctr(tc, tr, 2, 2), "圆树", fs, WHT)
for (bc, br) in bushes:
    label(*ctr(bc, br), "灌木", fs, WHT)
for (gc, gr) in grasses:
    label(ctr(gc, gr)[0], ctr(gc, gr)[1]+16, "草丛", fs, BLK)
for (sc, sr) in grass_strips:
    label(*ctr(sc, sr, 2, 1), "草带", fs, BLK)
for (fc_, fr_, _) in flowers:
    label(ctr(fc_, fr_)[0], ctr(fc_, fr_)[1]+16, "花", fs, BLK)
for (rc, rr) in rocks_big:
    label(*ctr(rc, rr), "大石", fs, WHT)
for (rc, rr) in rocks_small:
    label(*ctr(rc, rr), "小石", fs, WHT)
for (sc, sr) in stumps:
    label(*ctr(sc, sr), "树桩", fs, WHT)
for (cc, cr_) in campfires:
    label(*ctr(cc, cr_), "篝火", fs, WHT)
for (lc, lr) in logs:
    label(*ctr(lc, lr), "木堆", fs, WHT)

# =================================================================
# 统计
# =================================================================
used = set()
# 羊圈 5×5
for dc in range(pen_w):
    for dr in range(pen_h):
        used.add((pen_c + dc, pen_r + dr))
# 湖泊 4×3
for dc in range(lake_w):
    for dr in range(lake_h):
        used.add((lake_c + dc, lake_r + dr))
# 松树 2×2
for (pc, pr) in pines:
    for dc in range(2):
        for dr in range(2):
            used.add((pc + dc, pr + dr))
# 圆树 2×2
for (tc, tr) in round_trees:
    for dc in range(2):
        for dr in range(2):
            used.add((tc + dc, tr + dr))
# 灌木 1×1
for (bc, br) in bushes:
    used.add((bc, br))
# 草丛 1×1
for (gc, gr) in grasses:
    used.add((gc, gr))
# 草带 2×1
for (sc, sr) in grass_strips:
    used.add((sc, sr))
    used.add((sc+1, sr))
# 花丛 1×1
for (fc_, fr_, _) in flowers:
    used.add((fc_, fr_))
# 大石堆 1×1
for (rc, rr) in rocks_big:
    used.add((rc, rr))
# 小石堆 1×1
for (rc, rr) in rocks_small:
    used.add((rc, rr))
# 树桩 1×1
for (sc, sr) in stumps:
    used.add((sc, sr))
# 篝火 1×1
for (cc, cr_) in campfires:
    used.add((cc, cr_))
# 小木堆 1×1
for (lc, lr) in logs:
    used.add((lc, lr))

open_cells = 900 - len(used)

out = "/workspace/assets/image/赶羊关卡地图v8.png"
img.save(out, "PNG")
print(f"OK {W}x{H}, {COLS}x{ROWS}={COLS*ROWS} cells")
print(f"非空格子: {len(used)}, 空地: {open_cells}")
print(f"→ {out}")
