#!/usr/bin/env python3
"""Draws the pictures of the README: everything in assets/ (the banner, the stack picture, the badges, the icons and the
social preview). You do NOT need this to use spft: the pictures are already in the repository. Run it only if you want to
change them:

    python3 tools/make-assets.py                      # writes assets/*.svg
    python3 tools/make-assets.py --png chromium       # also writes social-preview.png (needs a browser and Pillow)
    python3 tools/make-assets.py --at 1.2 --out /tmp/x    # a still of the animations at second 1.2, for a preview
    python3 tools/make-assets.py --only banner.svg    # only this picture

It needs python3 and fonttools (pip install fonttools). With Pillow built with raqm the letters are kerned.
All the letters are turned into outlines, so the pictures look the same everywhere and need no web font. The font is
Inter (SIL Open Font License), the commands use DejaVu Sans Mono (free licence). They are looked for in /usr/share/fonts;
if yours are somewhere else, give the folder of the Inter .otf files with --font and the mono font file with --mono.
The animations are plain CSS (no script), they run once or loop slowly, and they stop when the viewer asks for less motion.
"""
import argparse
import math
import os
import subprocess
import sys

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

try:
    from PIL import ImageFont
    _RAQM = ImageFont.core.HAVE_RAQM if hasattr(ImageFont.core, "HAVE_RAQM") else False
except Exception:  # Pillow is optional: without it the letters are not kerned
    ImageFont = None
    _RAQM = False

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(os.path.dirname(HERE), "assets")

# --- the colours: a blueprint (cyanotype) with a traffic-light status ramp ---------------------------------------------
BG0 = "#071A2E"      # the darkest blue
BG1 = "#0B2B4B"      # the paper
PANEL = "#0E2F50"    # cards, pills
PANEL2 = "#14406B"   # a lighter card
LINE = "#2C5F94"     # thin lines
GRID = "#6FA8DC"     # the blueprint grid
INK = "#F2F8FF"      # text
CHALK = "#9CB7D1"    # quiet text
RED = "#FF5C5C"
AMBER = "#FFB224"
MINT = "#3DDC97"
OFF = "#123A5F"      # an LED that is off

FONT_DIR = "/usr/share/fonts"
AT = None            # seconds: freeze every animation at this time (for stills); None = real animations


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def num(v):
    s = ("%.1f" % v).rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


# --- letters as outlines -----------------------------------------------------------------------------------------------
class Face:
    def __init__(self, path):
        self.tt = TTFont(path)
        self.upem = self.tt["head"].unitsPerEm
        self.gs = self.tt.getGlyphSet()
        self.cmap = self.tt.getBestCmap()
        self.hmtx = self.tt["hmtx"]
        self.pil = None
        if ImageFont is not None and _RAQM:
            try:
                self.pil = ImageFont.truetype(path, self.upem, layout_engine=ImageFont.Layout.RAQM)
            except Exception:
                self.pil = None

    def _positions(self, text):
        """x of every letter in font units (kerned when Pillow has raqm) and the total advance."""
        if self.pil is not None:
            xs = [self.pil.getlength(text[:i + 1]) - self.pil.getlength(ch) for i, ch in enumerate(text)]
            return xs, self.pil.getlength(text)
        xs, x = [], 0
        for ch in text:
            xs.append(x)
            x += self.hmtx[self.cmap[ord(ch)]][0]
        return xs, x

    def width(self, text, size, tracking=0.0):
        _, total = self._positions(text)
        return total * size / self.upem + tracking * (len(text) - 1)

    def path(self, text, size, x, y, anchor="start", tracking=0.0):
        """The outline of the text as the d= of one <path>. (x, y) is the start of the baseline (or its middle / end)."""
        s = size / self.upem
        xs, _ = self._positions(text)
        w = self.width(text, size, tracking)
        x0 = x - w / 2 if anchor == "middle" else (x - w if anchor == "end" else x)
        out = []
        for i, ch in enumerate(text):
            if ch == " ":
                continue
            pen = SVGPathPen(self.gs, ntos=num)
            self.gs[self.cmap[ord(ch)]].draw(TransformPen(pen, (s, 0, 0, -s, x0 + xs[i] * s + i * tracking, y)))
            out.append(pen.getCommands())
        return " ".join(out)


_faces = {}


def face(kind):
    if kind not in _faces:
        _faces[kind] = Face(FONTS[kind])
    return _faces[kind]


FONTS = {
    "regular": FONT_DIR + "/opentype/inter/Inter-Regular.otf",
    "medium": FONT_DIR + "/opentype/inter/Inter-Medium.otf",
    "semi": FONT_DIR + "/opentype/inter/Inter-SemiBold.otf",
    "bold": FONT_DIR + "/opentype/inter/Inter-Bold.otf",
    "mono": FONT_DIR + "/truetype/dejavu/DejaVuSansMono.ttf",
}


def text(kind, s, size, x, y, fill, anchor="start", tracking=0.0, cls=None, opacity=None):
    d = face(kind).path(s, size, x, y, anchor, tracking)
    extra = (' class="%s"' % cls if cls else "") + (' opacity="%s"' % opacity if opacity is not None else "")
    return '<path d="%s" fill="%s"%s/>' % (d, fill, extra)


# --- animation helpers ---------------------------------------------------------------------------------------------------
def A(name, dur, delay=0.0, count="1", fill="none", timing="linear"):
    """One animation: its name, length in seconds, delay, how many times, fill mode and timing."""
    return (name, dur, delay, count, fill, timing)


def anim(*specs):
    """The CSS `animation` declaration for one or more animations. With --at they are frozen at that second (stills)."""
    parts = []
    for (name, dur, delay, count, fill, timing) in specs:
        d = delay if AT is None else delay - AT
        parts.append("%s %ss %s %ss %s %s" % (name, num(dur), timing, num(d), count, fill))
    return "animation:" + ",".join(parts) + ("" if AT is None else ";animation-play-state:paused")


CALM = "@media (prefers-reduced-motion:reduce){*{animation:none!important}}"


def svg(w, h, title, body, css="", defs="", desc=None):
    style = "<style>%s%s</style>" % (css, CALM) if css else ""
    d = "<desc>%s</desc>" % esc(desc) if desc else ""
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img" aria-labelledby="ttl">'
            '<title id="ttl">%s</title>%s%s<defs>%s</defs>%s</svg>\n') % (w, h, w, h, esc(title), d, style, defs, body)


# --- the LED letters of the wordmark: 5 columns wide, rows 0..8 (the p hangs below the line) ----------------------------------
LED = {
    "s": (2, ["01111", "10000", "01110", "00001", "11110"]),
    "p": (2, ["11110", "10001", "10001", "10001", "11110", "10000", "10000"]),
    "f": (0, ["00111", "01000", "11110", "01000", "01000", "01000", "01000"]),
    "t": (1, ["01000", "11110", "01000", "01000", "01001", "00110"]),
}


def led_cells(word, gap):
    """[(column, row)] of every lit LED, and the number of columns."""
    cells, col = [], 0
    for ch in word:
        top, rows = LED[ch]
        for r, line in enumerate(rows):
            for c, bit in enumerate(line):
                if bit == "1":
                    cells.append((col + c, top + r))
        col += 5 + gap
    return cells, col - gap


def grid_defs(w, h, step=32):
    return ('<pattern id="grid" width="%d" height="%d" patternUnits="userSpaceOnUse">'
            '<path d="M %d 0 H 0 V %d" fill="none" stroke="%s" stroke-width="1" opacity=".16"/></pattern>'
            '<radialGradient id="fade" cx="50%%" cy="42%%" r="62%%"><stop offset="0" stop-color="#fff"/>'
            '<stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>'
            '<mask id="gridmask"><rect width="%d" height="%d" fill="url(#fade)"/></mask>') % (step, step, step, step, GRID, w, h)


def phone(x, y, w, h, led, led_attrs="", stroke=CHALK, fill=BG0):
    cx = x + w / 2
    return ('<rect x="%s" y="%s" width="%s" height="%s" rx="10" fill="%s" stroke="%s" stroke-width="2.5"/>'
            '<path d="M %s %s H %s" stroke="%s" stroke-width="2.5" stroke-linecap="round"/>'
            '<circle cx="%s" cy="%s" r="6" fill="%s" %s/>') % (
        num(x), num(y), num(w), num(h), fill, stroke, num(cx - 6), num(y + 9), num(cx + 6), stroke,
        num(cx), num(y + h / 2 + 3), led, led_attrs)


# --- 1. the banner -----------------------------------------------------------------------------------------------------------
def banner(frame=True):
    W, H = 1280, 430
    half = 150                     # half the distance between the two phones
    P, R = 24, 8.4                 # the pitch of the LEDs and their radius
    word, gap = "spft", 1
    cells, cols = led_cells(word, gap)
    rows = 9
    mw = (cols - 1) * P
    x0 = (W - mw) / 2
    y0 = 58

    # the unlit matrix goes a little beyond the letters and fades out
    mx, my = x0 - 3 * P, y0 - 2 * P
    mwid, mhei = mw + 6 * P, (rows - 1) * P + 4 * P
    defs = grid_defs(W, H)
    defs += ('<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>'
             '<radialGradient id="halo" cx="50%%" cy="30%%" r="46%%"><stop offset="0" stop-color="%s" stop-opacity=".16"/><stop offset="1" stop-color="%s" stop-opacity="0"/></radialGradient>'
             '<pattern id="off" x="%s" y="%s" width="%d" height="%d" patternUnits="userSpaceOnUse"><circle cx="%s" cy="%s" r="6.2" fill="%s"/></pattern>'
             '<radialGradient id="fade2" cx="50%%" cy="50%%" r="60%%"><stop offset=".55" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>'
             '<mask id="offmask"><rect x="%s" y="%s" width="%s" height="%s" fill="url(#fade2)"/></mask>'
             '<filter id="glow" x="-20%%" y="-30%%" width="140%%" height="160%%"><feGaussianBlur stdDeviation="6" result="b"/>'
             '<feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>'
             '<linearGradient id="tail" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="%s" stop-opacity="0"/><stop offset="1" stop-color="%s"/></linearGradient>'
             ) % (BG0, BG1, MINT, MINT, num(x0 - P / 2), num(y0 - P / 2), P, P, P / 2, P / 2, OFF,
                  num(mx), num(my), num(mwid), num(mhei), MINT, MINT)

    css = []
    css.append("@keyframes boot{0%{fill:" + OFF + "}14%{fill:" + RED + "}46%{fill:" + AMBER + "}100%{fill:" + MINT + "}}")
    css.append(".d{fill:" + MINT + "}")
    css.append("@keyframes shine{0%{opacity:0}14%{opacity:.3}100%{opacity:.3}}")
    css.append("@keyframes shimmer{0%,91%{fill:" + MINT + "}95.5%{fill:#D9FFEC}100%{fill:" + MINT + "}}")
    css.append(".sh{fill:#fff;opacity:.3}")
    for c in range(cols):
        # first the boot (red, amber, green, from left to right), then every few seconds a quick shimmer runs over the letters
        css.append(".c%d{%s}" % (c, anim(A("boot", 1.25, 0.2 + c * 0.075, "1", "backwards"), A("shimmer", 7.5, 3.9 + c * 0.045, "infinite", "none"))))
        css.append(".e%d{%s}" % (c, anim(A("shine", 1.25, 0.2 + c * 0.075, "1", "backwards"))))
    # the data pulse that crosses the cable and brings the broken phone back to life, again and again
    LOOP = 4.8
    dist = 2 * half - 48           # how far the pulse travels: from the left phone to the right one
    css.append("@keyframes go{0%{transform:translateX(0);opacity:0}6%{opacity:1}62%{transform:translateX(" + num(dist) + "px);opacity:1}68%{transform:translateX(" + num(dist) + "px);opacity:0}100%{transform:translateX(" + num(dist) + "px);opacity:0}}")
    css.append("@keyframes alive{0%,64%{fill:" + RED + "}70%{fill:" + MINT + "}94%{fill:" + MINT + "}100%{fill:" + RED + "}}")
    css.append("@keyframes ring{0%,64%{opacity:0;transform:scale(.6)}70%{opacity:.9}94%{opacity:0;transform:scale(2.4)}100%{opacity:0}}")
    css.append(".pulse{opacity:0;%s}" % anim(A("go", LOOP, 3.2, "infinite", "none")))
    css.append(".led2{fill:" + RED + ";%s}" % anim(A("alive", LOOP, 3.2, "infinite", "none")))
    css.append(".ring{transform-box:fill-box;transform-origin:center;opacity:0;%s}" % anim(A("ring", LOOP, 3.2, "infinite", "none")))
    css = "".join(css)

    defs += '<clipPath id="card"><rect width="%d" height="%d" rx="22"/></clipPath>' % (W, H)
    b = []
    b.append('<rect width="%d" height="%d" fill="url(#bg)"/>' % (W, H))
    b.append('<rect width="%d" height="%d" fill="url(#grid)" mask="url(#gridmask)"/>' % (W, H))
    b.append('<rect width="%d" height="%d" fill="url(#halo)"/>' % (W, H))
    # little registration marks in the corners, like on a drawing
    for (cx, cy) in ((28, 28), (W - 28, 28), (28, H - 28), (W - 28, H - 28)):
        b.append('<path d="M %d %d h 14 M %d %d v 14" stroke="%s" stroke-width="1.5" opacity=".5" stroke-linecap="round" transform="translate(-7 -7)"/>' % (cx, cy + 7, cx + 7, cy, CHALK))
    # the LED board
    b.append('<rect x="%s" y="%s" width="%s" height="%s" fill="url(#off)" mask="url(#offmask)"/>' % (num(mx), num(my), num(mwid), num(mhei)))
    lit = []
    for (c, r) in cells:
        lit.append('<circle class="d c%d" cx="%s" cy="%s" r="%s"/>' % (c, num(x0 + c * P), num(y0 + r * P), num(R)))
    b.append('<g filter="url(#glow)">%s</g>' % "".join(lit))
    # a small shine on every LED
    shine = []
    for (c, r) in cells:
        shine.append('<circle class="sh e%d" cx="%s" cy="%s" r="2.4"/>' % (c, num(x0 + c * P - 2.6), num(y0 + r * P - 2.8)))
    b.append("".join(shine))

    # the caption under the board
    ty = y0 + (rows - 1) * P + 50
    b.append(text("medium", "SP Flash Tool on an Android phone", 24, W / 2, ty, CHALK, "middle", 0.6))

    # the cable: a rooted phone (left) flashes a broken one (right); the words stand beside the phones
    cy = ty + 58
    ph_w, ph_h = 42, 70
    lx = W / 2 - half - ph_w
    rx = W / 2 + half
    b.append(phone(lx, cy - ph_h / 2, ph_w, ph_h, MINT))
    b.append(phone(rx, cy - ph_h / 2, ph_w, ph_h, RED, 'class="led2"'))
    b.append('<circle class="ring" cx="%s" cy="%s" r="9" fill="none" stroke="%s" stroke-width="2"/>' % (num(rx + ph_w / 2), num(cy + 3), MINT))
    cable_x1, cable_x2 = lx + ph_w + 2, rx - 2
    b.append('<path d="M %s %s H %s" stroke="%s" stroke-width="2.5" stroke-linecap="round" fill="none"/>' % (num(cable_x1), num(cy), num(cable_x2), LINE))
    b.append('<g class="pulse"><rect x="%s" y="%s" width="46" height="4" rx="2" fill="url(#tail)"/><circle cx="%s" cy="%s" r="5" fill="%s" filter="url(#glow)"/></g>'
             % (num(cable_x1 - 6), num(cy - 2), num(cable_x1 + 40), num(cy), MINT))
    b.append(text("regular", "your rooted phone", 19, lx - 22, cy + 7, CHALK, "end"))
    b.append(text("regular", "the device to fix", 19, rx + ph_w + 22, cy + 7, CHALK, "start"))
    return svg(W, H, "spft: SP Flash Tool on an Android phone", '<g clip-path="url(#card)">' + "".join(b) + "</g>", css, defs,
               "The word spft as a board of LEDs that light up red, amber, green. Below, a rooted phone sends data over a cable to a broken phone, which comes back to life.")


# --- 2. the badges: small pills, one picture each ----------------------------------------------------------------------------
BADGES = [
    # file name,        label,       value,         the dot
    ("badge-root.svg",    "root",      "required",    AMBER),
    ("badge-android.svg", "Android",   "8 and newer", MINT),
    ("badge-kernel.svg",  "kernel",    "64-bit",      MINT),
    ("badge-mtk.svg",     "flashes",   "MediaTek",    MINT),
    ("badge-license.svg", "license",   "MIT",         MINT),
]


def badge(label, value, dot=MINT):
    H, size = 30, 13
    fl, fv = face("medium"), face("semi")
    lw, vw = fl.width(label, size), fv.width(value, size)
    left = 14 + 8 + 8 + lw + 11          # padding, the dot, a gap, the label, a gap
    right = 11 + vw + 15
    w = int(math.ceil(left + right))
    left = w - right
    base = H / 2 + size * 0.36
    body = ('<clipPath id="pill"><rect x=".5" y=".5" width="%s" height="%s" rx="%s"/></clipPath>'
            '<rect x=".5" y=".5" width="%s" height="%s" rx="%s" fill="%s"/>'
            '<rect x="%s" y="0" width="%s" height="%d" fill="%s" clip-path="url(#pill)"/>'
            '<rect x=".5" y=".5" width="%s" height="%s" rx="%s" fill="none" stroke="%s"/>'
            '<circle cx="21" cy="%s" r="7" fill="%s" opacity=".18"/><circle cx="21" cy="%s" r="3.6" fill="%s"/>'
            '%s%s') % (
        num(w - 1), num(H - 1), num(H / 2 - .5),
        num(w - 1), num(H - 1), num(H / 2 - .5), PANEL,
        num(left), num(right), H, PANEL2,
        num(w - 1), num(H - 1), num(H / 2 - .5), LINE,
        num(H / 2), dot, num(H / 2), dot,
        text("medium", label, size, 14 + 8 + 8, base, CHALK),
        text("semi", value, size, left + 11, base, INK))
    return svg(w, H, "%s: %s" % (label, value), body)


# --- 3. icons on a small tile --------------------------------------------------------------------------------------------------
# drawn on a 24 x 24 grid with a round pen
ICONS = {
    "phone": '<rect x="7" y="2.5" width="10" height="19" rx="2.6"/><path d="M10.4 5.6h3.2"/><circle cx="12" cy="17.6" r=".6" fill="CURRENT"/>',
    "bolt": '<path d="M13.2 2.6 5.2 13.6h6l-.9 7.8 8.5-11.4h-6z"/>',
    "shield": '<path d="M12 2.8 4.6 5.8v5.5c0 4.5 3 8.5 7.4 9.9 4.4-1.4 7.4-5.4 7.4-9.9V5.8z"/><path d="m8.7 12.2 2.4 2.4 4.3-4.7"/>',
    "book": '<path d="M5.2 4.4h10.4a2.4 2.4 0 0 1 2.4 2.4V20H7.6a2.4 2.4 0 0 1-2.4-2.4z"/><path d="M5.2 17.6a2.4 2.4 0 0 1 2.4-2.4H18"/>',
    "help": '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3.6"/><path d="m5.7 5.7 3.8 3.8M14.5 14.5l3.8 3.8M18.3 5.7l-3.8 3.8M9.5 14.5l-3.8 3.8"/>',
    "layers": '<path d="m12 3.2 8.8 4.4-8.8 4.4-8.8-4.4z"/><path d="m3.2 12 8.8 4.4 8.8-4.4"/><path d="m3.2 16.4 8.8 4.4 8.8-4.4"/>',
    "play": '<path d="M8.4 5.4v13.2L19.2 12z"/>',
    "terminal": '<rect x="3" y="4.6" width="18" height="14.8" rx="2.6"/><path d="m7.4 10 3 2.4-3 2.4M12.6 15h4"/>',
    "apps": '<rect x="4" y="4" width="6.8" height="6.8" rx="1.8"/><rect x="13.2" y="4" width="6.8" height="6.8" rx="1.8"/><rect x="4" y="13.2" width="6.8" height="6.8" rx="1.8"/><rect x="13.2" y="13.2" width="6.8" height="6.8" rx="1.8"/>',
}


ICONS_USED = ["phone", "bolt", "shield", "book", "help", "layers"]      # the ones the README shows on their own


def icon_at(name, x, y, size, fill=BG0, stroke=LINE, pen=MINT):
    """The icon tile as a group at (x, y), to put inside another picture."""
    return ('<g transform="translate(%s %s)"><rect x=".75" y=".75" width="%s" height="%s" rx="%s" fill="%s" stroke="%s" stroke-width="1.5"/>'
            '<g transform="translate(%s %s) scale(%s)" fill="none" stroke="%s" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">%s</g></g>') % (
        num(x), num(y), num(size - 1.5), num(size - 1.5), num(size * 0.25), fill, stroke,
        num(size * 0.25), num(size * 0.25), num(size * 0.5 / 24), pen, ICONS[name].replace("CURRENT", pen))


def icon(name, size=64):
    k = size / 64.0
    body = ('<rect x=".75" y=".75" width="%s" height="%s" rx="%s" fill="%s" stroke="%s" stroke-width="1.5"/>'
            '<g transform="translate(%s %s) scale(%s)" fill="none" stroke="%s" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">%s</g>') % (
        num(size - 1.5), num(size - 1.5), num(size * 0.25), PANEL, LINE,
        num(size * 0.25), num(size * 0.25), num(size * 0.5 / 24), MINT, ICONS[name].replace("CURRENT", MINT))
    return svg(size, size, name, body)


# --- 4. a terminal that runs `spft check` ----------------------------------------------------------------------------------------
CHECK_LINES = [
    # (text, colour), exactly what `spft check` prints on a good host
    ("== Termux ==", CHALK),
    ("root      : su found, and root works", INK),
    ("x11-pkg   : installed", INK),
    ("x11-app   : Termux:X11 app installed", INK),
    ("== phone and Debian ==", CHALK),
    ("kernel    : 64-bit ARM (CONFIG_ARM64=y) - OK, a 32-bit Android userspace doesn't matter", INK),
    ("cdc_acm   : present - OK (the USB serial driver SP Flash Tool talks through)", INK),
    ("android   : 11 (API 30), ABIs: arm64-v8a,armeabi-v7a,armeabi", INK),
    ("free      : 27360 MB on /data (the install needs about 3000)", INK),
    ("== Result ==", CHALK),
    ("spft can be installed and started on this device.", MINT),
]


def terminal():
    W, pad, lh, fs = 960, 30, 25, 14.4
    top = 56
    H = top + 18 + lh * (len(CHECK_LINES) + 2) + 14
    css = ["@keyframes type{0%{opacity:0}100%{opacity:1}}",
           "@keyframes caret{0%,49%{opacity:1}50%,100%{opacity:0}}", ".ln{opacity:1}"]
    body = ['<rect x=".75" y=".75" width="%d" height="%s" rx="16" fill="%s" stroke="%s" stroke-width="1.5"/>' % (W - 1.5, num(H - 1.5), BG0, LINE),
            '<path d="M .75 %d V 17 a 16 16 0 0 1 16 -16 H %d a 16 16 0 0 1 16 16 V %d z" fill="%s"/>' % (top, W - 16.75, top, PANEL),
            '<path d="M 1 %d H %d" stroke="%s" stroke-width="1.5"/>' % (top, W - 1, LINE)]
    for i, c in enumerate((RED, AMBER, MINT)):
        body.append('<circle cx="%d" cy="%d" r="6.5" fill="%s"/>' % (30 + i * 22, top / 2, c))
    body.append(text("medium", "Termux", 15, W / 2, top / 2 + 5.4, CHALK, "middle"))
    mono_w = face("mono").width("0", fs)
    y = top + 18 + lh * 0.75
    # the command line: typed first
    t0 = 0.5
    body.append('<g class="ln l0">' + text("mono", "$", fs, pad, y, MINT) + text("mono", "spft check", fs, pad + 2 * mono_w, y, INK) + "</g>")
    css.append(".l0{%s}" % anim(A("type", 0.4, t0, "1", "backwards", "steps(1,end)")))
    for i, (t, col) in enumerate(CHECK_LINES):
        y2 = y + lh * (i + 1.35)
        body.append('<g class="ln l%d">%s</g>' % (i + 1, text("mono", t, fs, pad, y2, col)))
        css.append(".l%d{%s}" % (i + 1, anim(A("type", 0.25, 1.6 + i * 0.42, "1", "backwards", "steps(1,end)"))))
    # a new prompt with a block cursor that blinks, after the last line
    end_y = y + lh * (len(CHECK_LINES) + 1.35)
    t_end = 1.6 + len(CHECK_LINES) * 0.42
    body.append('<g class="ln pr">%s</g>' % text("mono", "$", fs, pad, end_y, MINT))
    css.append(".pr{%s}" % anim(A("type", 0.25, t_end, "1", "backwards", "steps(1,end)")))
    body.append('<g class="cur"><rect x="%s" y="%s" width="%s" height="%s" fill="%s"/></g>' % (num(pad + 2 * mono_w), num(end_y - fs * 0.82), num(mono_w), num(fs * 1.02), MINT))
    css.append(".cur{opacity:0;%s}" % anim(A("caret", 1.1, t_end + 0.3, "infinite", "none", "steps(1,end)")))
    return svg(W, int(H), "spft check in a terminal: every line says OK, and the result is that spft can be installed on this device", "".join(body), "".join(css))


# --- 5. what spft puts on the phone: the stack and the cable ------------------------------------------------------------------------
def stack():
    W, H = 1100, 392
    layers = [
        ("SP Flash Tool", "the program you use, shown by Termux:X11", True),
        ("box64", "runs x86_64 programs on an arm64 phone", False),
        ("Debian (chroot)", "a small Linux system inside your phone", False),
        ("Termux + root", "where you type spft", False),
    ]
    cx0, cx1 = 28, 706
    css = ["@keyframes flow{to{stroke-dashoffset:-36}}", ".cable{stroke-dasharray:6 12;%s}" % anim(A("flow", 1.6, 0, "infinite", "none")),
           "@keyframes alive{0%,64%{fill:" + RED + "}70%{fill:" + MINT + "}94%{fill:" + MINT + "}100%{fill:" + RED + "}}",
           ".led2{fill:" + RED + ";%s}" % anim(A("alive", 4.8, 0.5, "infinite", "none"))]
    defs = grid_defs(W, H) + ('<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>'
                              '<clipPath id="card"><rect width="%d" height="%d" rx="22"/></clipPath>') % (BG0, BG1, W, H)
    b = ['<rect width="%d" height="%d" fill="url(#bg)"/>' % (W, H),
         '<rect width="%d" height="%d" fill="url(#grid)" mask="url(#gridmask)"/>' % (W, H),
         '<rect x="%d" y="28" width="%d" height="%d" rx="20" fill="%s" stroke="%s" stroke-width="1.5"/>' % (cx0, cx1 - cx0, H - 56, PANEL, LINE)]
    b.append(text("semi", "Your rooted phone", 22, cx0 + 28, 74, INK))
    b.append(text("regular", "the host", 17, cx1 - 28, 74, CHALK, "end"))
    y = 98
    for name, note, hot in layers:
        bh = 56
        fill, stroke = ("#0F3F38", MINT) if hot else (BG1, LINE)
        inner = cx1 - cx0 - 40
        need = 62 + face("semi").width(name, 20) + 24 + face("regular").width(note, 16) + 24
        assert need < inner, "the note of %r does not fit its bar (%d > %d)" % (name, need, inner)
        b.append('<rect x="%d" y="%d" width="%d" height="%d" rx="13" fill="%s" stroke="%s" stroke-width="%s"/>' % (cx0 + 20, y, inner, bh, fill, stroke, "2" if hot else "1.5"))
        b.append('<circle cx="%d" cy="%s" r="5" fill="%s"/>' % (cx0 + 44, num(y + bh / 2), MINT if hot else LINE))
        b.append(text("semi", name, 20, cx0 + 62, y + bh / 2 + 7, INK))
        b.append(text("regular", note, 16, cx1 - 40, y + bh / 2 + 5.8, MINT if hot else CHALK, "end"))
        y += bh + 10
    # the cable, with the words above it
    cy = H / 2
    b.append('<path class="cable" d="M %d %s H 884" stroke="%s" stroke-width="3" stroke-linecap="round" fill="none"/>' % (cx1 + 8, num(cy), MINT))
    b.append(text("medium", "OTG adapter", 17, (cx1 + 884) / 2, cy - 38, CHALK, "middle"))
    b.append(text("medium", "and a data cable", 17, (cx1 + 884) / 2, cy - 15, CHALK, "middle"))
    # the device to fix
    pw, ph = 112, 200
    px = 896
    py = cy - ph / 2 - 14
    b.append('<rect x="%d" y="%s" width="%d" height="%d" rx="20" fill="%s" stroke="%s" stroke-width="3"/>' % (px, num(py), pw, ph, BG0, CHALK))
    b.append('<path d="M %d %s H %d" stroke="%s" stroke-width="3" stroke-linecap="round"/>' % (px + pw / 2 - 14, num(py + 20), px + pw / 2 + 14, CHALK))
    b.append('<circle class="led2" cx="%d" cy="%s" r="11" fill="%s"/>' % (px + pw / 2, num(py + ph / 2 + 8), RED))
    b.append(text("semi", "The device to fix", 17, px + pw / 2, py + ph + 34, INK, "middle"))
    b.append(text("regular", "MediaTek, switched off", 16, px + pw / 2, py + ph + 57, CHALK, "middle"))
    return svg(W, H, "How it works: a rooted phone runs Termux, Debian, box64 and SP Flash Tool, and talks over an OTG cable to the MediaTek device you want to fix",
               '<g clip-path="url(#card)">' + "".join(b) + "</g>", "".join(css), defs)


# --- 5b. the three steps at a glance ---------------------------------------------------------------------------------------------
def steps():
    W, H = 1280, 224
    cards = [
        ("1", "apps", "Get the apps", ["Termux and Termux:X11,", "not from Google Play"]),
        ("2", "terminal", "Install spft", ["One line, once.", "About 15 to 30 minutes."]),
        ("3", "play", "Start it", ["Type spft.", "That is all."]),
    ]
    cw, gap, ch = 372, 62, 148
    x0 = (W - (3 * cw + 2 * gap)) / 2
    y0 = 44
    defs = grid_defs(W, H) + ('<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>'
                              '<clipPath id="card"><rect width="%d" height="%d" rx="22"/></clipPath>') % (BG0, BG1, W, H)
    b = ['<rect width="%d" height="%d" fill="url(#bg)"/>' % (W, H),
         '<rect width="%d" height="%d" fill="url(#grid)" mask="url(#gridmask)"/>' % (W, H)]
    for i, (n, ic, title, caps) in enumerate(cards):
        x = x0 + i * (cw + gap)
        need = 128 + max([face("semi").width(title, 27)] + [face("regular").width(c, 18) for c in caps]) + 20
        assert need < cw, "the card %r is too narrow (%d > %d)" % (title, need, cw)
        b.append('<rect x="%s" y="%d" width="%d" height="%d" rx="20" fill="%s" stroke="%s" stroke-width="1.5"/>' % (num(x), y0, cw, ch, PANEL, LINE))
        b.append(icon_at(ic, x + 28, y0 + (ch - 76) / 2, 76))
        b.append(text("semi", title, 27, x + 126, y0 + 56, INK))
        for k, cap in enumerate(caps):
            b.append(text("regular", cap, 18, x + 126, y0 + 88 + 25 * k, CHALK))
        # the step number sits on the corner of the card
        b.append('<circle cx="%s" cy="%d" r="19" fill="%s" stroke="%s" stroke-width="4"/>' % (num(x + 4), y0 + 2, MINT, BG0))
        b.append(text("bold", n, 21, x + 4, y0 + 2 + 7.4, BG0, "middle"))
        if i < 2:
            ax = x + cw + gap / 2
            ay = y0 + ch / 2
            b.append('<path d="M %s %s l 12 13 l -12 13" fill="none" stroke="%s" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"/>' % (num(ax - 6), num(ay - 13), MINT))
    return svg(W, H, "Three steps: get the apps, install spft, start it", '<g clip-path="url(#card)">' + "".join(b) + "</g>", "", defs)


# --- 6. the picture that GitHub shows when the repository is shared ------------------------------------------------------------------
def social():
    W, H = 1280, 640
    P, R = 28, 9.8
    cells, cols = led_cells("spft", 1)
    rows = 9
    mw = (cols - 1) * P
    x0 = (W - mw) / 2
    y0 = 92
    defs = grid_defs(W, H, 40)
    defs += ('<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>'
             '<radialGradient id="halo" cx="50%%" cy="32%%" r="48%%"><stop offset="0" stop-color="%s" stop-opacity=".18"/><stop offset="1" stop-color="%s" stop-opacity="0"/></radialGradient>'
             '<pattern id="off" x="%s" y="%s" width="%d" height="%d" patternUnits="userSpaceOnUse"><circle cx="%s" cy="%s" r="7.2" fill="%s"/></pattern>'
             '<radialGradient id="fade2" cx="50%%" cy="50%%" r="60%%"><stop offset=".55" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>'
             '<mask id="offmask"><rect x="%s" y="%s" width="%s" height="%s" fill="url(#fade2)"/></mask>'
             '<filter id="glow" x="-20%%" y="-30%%" width="140%%" height="160%%"><feGaussianBlur stdDeviation="7" result="b"/>'
             '<feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>'
             ) % (BG0, BG1, MINT, MINT, num(x0 - P / 2), num(y0 - P / 2), P, P, P / 2, P / 2, OFF,
                  num(x0 - 3 * P), num(y0 - 2 * P), num(mw + 6 * P), num((rows - 1) * P + 4 * P))
    b = ['<rect width="%d" height="%d" fill="url(#bg)"/>' % (W, H),
         '<rect width="%d" height="%d" fill="url(#grid)" mask="url(#gridmask)"/>' % (W, H),
         '<rect width="%d" height="%d" fill="url(#halo)"/>' % (W, H),
         '<rect x="%s" y="%s" width="%s" height="%s" fill="url(#off)" mask="url(#offmask)"/>' % (num(x0 - 3 * P), num(y0 - 2 * P), num(mw + 6 * P), num((rows - 1) * P + 4 * P))]
    b.append('<g filter="url(#glow)" fill="%s">%s</g>' % (MINT, "".join('<circle cx="%s" cy="%s" r="%s"/>' % (num(x0 + c * P), num(y0 + r * P), num(R)) for c, r in cells)))
    b.append('<g fill="#fff" opacity=".3">%s</g>' % "".join('<circle cx="%s" cy="%s" r="2.7"/>' % (num(x0 + c * P - 3), num(y0 + r * P - 3.2)) for c, r in cells))
    ty = y0 + (rows - 1) * P + 86
    b.append(text("bold", "SP Flash Tool on an Android phone", 48, W / 2, ty, INK, "middle", -0.5))
    b.append(text("regular", "Unbrick a MediaTek phone with just another rooted phone. No PC.", 27, W / 2, ty + 50, CHALK, "middle"))
    # the cable row, small
    cy = ty + 112
    ph_w, ph_h, half = 34, 56, 130
    b.append(phone(W / 2 - half - ph_w, cy - ph_h / 2, ph_w, ph_h, MINT))
    b.append(phone(W / 2 + half, cy - ph_h / 2, ph_w, ph_h, RED))
    b.append('<path d="M %s %s H %s" stroke="%s" stroke-width="2.5" stroke-linecap="round"/>' % (num(W / 2 - half + 2), num(cy), num(W / 2 + half - 2), LINE))
    return svg(W, H, "spft: SP Flash Tool on an Android phone", "".join(b), "", defs)


def write_png(browser, svg_path, png_path, w, h):
    """A picture of the SVG, with a headless browser (chrome-headless-shell gives the exact size; other browsers are cropped to it)."""
    import tempfile
    from PIL import Image
    with tempfile.TemporaryDirectory() as d:
        page = os.path.join(d, "p.html")
        shot = os.path.join(d, "s.png")
        with open(page, "w", encoding="utf-8") as f:
            f.write('<!doctype html><meta charset="utf-8"><style>html,body{margin:0;background:%s}img{display:block}</style><img src="file://%s" width="%d" height="%d">'
                    % (BG1, os.path.abspath(svg_path), w, h))
        subprocess.run([browser, "--no-sandbox", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1", "--allow-file-access-from-files",
                        "--virtual-time-budget=2000", "--window-size=%d,%d" % (w, h + 200), "--screenshot=" + shot, "file://" + page],
                       check=True, capture_output=True)
        Image.open(shot).convert("RGB").crop((0, 0, w, h)).save(png_path, optimize=True)
    print("wrote", png_path)


def main():
    global AT
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=ASSETS, help="where to write (default: assets/)")
    ap.add_argument("--at", type=float, default=None, help="freeze the animations at this second (stills for a preview)")
    ap.add_argument("--png", metavar="BROWSER", help="also write social-preview.png (next to the .svg) with this browser (chromium / google-chrome)")
    ap.add_argument("--font", metavar="DIR", help="folder with Inter-Regular.otf, Inter-Medium.otf, Inter-SemiBold.otf and Inter-Bold.otf (default %s)" % (FONT_DIR + "/opentype/inter"))
    ap.add_argument("--mono", metavar="FILE", help="the monospace font file (default %s)" % FONTS["mono"])
    ap.add_argument("--only", nargs="*", help="only these files")
    a = ap.parse_args()
    AT = a.at
    if a.font:
        for kind, fn_ in (("regular", "Inter-Regular.otf"), ("medium", "Inter-Medium.otf"), ("semi", "Inter-SemiBold.otf"), ("bold", "Inter-Bold.otf")):
            FONTS[kind] = os.path.join(a.font, fn_)
    if a.mono:
        FONTS["mono"] = a.mono
    missing = sorted(set(p for p in FONTS.values() if not os.path.isfile(p)))
    if missing:
        sys.exit("make-assets: these font files were not found:\n  %s\nInstall Inter and DejaVu Sans Mono (Debian: apt install fonts-inter fonts-dejavu-core), "
                 "or give --font DIR and --mono FILE." % "\n  ".join(missing))
    os.makedirs(a.out, exist_ok=True)
    files = {"banner.svg": banner, "steps.svg": steps, "terminal.svg": terminal, "stack.svg": stack, "social-preview.svg": social}
    for fn_, label, value, dot in BADGES:
        files[fn_] = (lambda l=label, v=value, d=dot: badge(l, v, d))
    for nm in ICONS_USED:
        files["icon-%s.svg" % nm] = (lambda n=nm: icon(n))
    for name, fn in files.items():
        if a.only and name not in a.only:
            continue
        with open(os.path.join(a.out, name), "w", encoding="utf-8", newline="\n") as f:
            f.write(fn())
        print("wrote", os.path.join(a.out, name))
    if a.png:
        write_png(a.png, os.path.join(a.out, "social-preview.svg"), os.path.join(a.out, "social-preview.png"), 1280, 640)


if __name__ == "__main__":
    main()
