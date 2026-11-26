#!/usr/bin/env python3
"""Draws the Salvager windows from the layout dump (SDD 94) and lists the layout problems.

  layout.py              copy the saved variables from INSTALL_HOST, then draw
  layout.py --file PATH  draw from a local copy of Salvager.lua

Reads INSTALL_HOST and ADDONS_DIR from the environment (the Makefile loads .env). The saved variables are
<ADDONS_DIR>/../../WTF/Account/*/SavedVariables/Salvager.lua (the newest one). Writes into .agents/tmp/layout/:
Salvager.lua (mode 0600: the player's own data), <window>.svg and <window>.png (PNG with rsvg-convert in Docker,
image salvager-layout from scripts/layout/Dockerfile).
"""
import html
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, ".agents", "tmp", "layout")
IMAGE = "salvager-layout"
PAD, FOOT = 16, 20
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "RequestTTY=no"]
COIN = {"Gold": "#ffd100", "Silver": "#c7c7cf", "Copper": "#c8602c"}
LAYERS = {"BG": 0, "BD": 1, "A": 2, "O": 3}
MAX_LISTED = 25   # problems listed per window; the rest are counted


def fail(msg):
    sys.exit(f"layout: {msg}")


# ---------- saved variables ----------

def fetch():
    host, addons = os.environ.get("INSTALL_HOST"), os.environ.get("ADDONS_DIR")
    if not host or not addons:
        fail("set INSTALL_HOST and ADDONS_DIR in .env")
    pattern = f"{addons}/../../WTF/Account/*/SavedVariables/Salvager.lua"
    ps = (f'Get-ChildItem -Path "{pattern}" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | '
          f'Select-Object -First 1 | ForEach-Object {{ $_.FullName + "|" + $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm") }}')
    try:
        r = subprocess.run(SSH + [host, ps], capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        fail(f"{host} did not answer in 30 s")
    if r.returncode == 255:
        fail(f"cannot reach {host} over SSH: {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'no answer'}")
    line = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    if "|" not in line:
        fail(f"no Salvager.lua under WTF/Account/*/SavedVariables on {host} (log in once with the addon)")
    path, written = line.rsplit("|", 1)
    os.makedirs(OUT, exist_ok=True)
    local = os.path.join(OUT, "Salvager.lua")
    old = os.umask(0o077)
    try:
        r = subprocess.run(["scp", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                            f"{host}:{path.replace(chr(92), '/')}", local], capture_output=True, text=True, timeout=120)
    finally:
        os.umask(old)
    if r.returncode != 0:
        fail(f"copy from {host} failed: {r.stderr.strip()}")
    os.chmod(local, 0o600)
    print(f"saved variables: written {written} on {host}")
    return local


class Lua:
    """The subset of Lua the game writes into saved variables: tables, strings, numbers, booleans, nil."""
    TOKEN = re.compile(r'\s+|--[^\n]*|"(?:[^"\\]|\\.)*"|\[|\]|\{|\}|=|,|;|[A-Za-z_][A-Za-z0-9_]*|[-+0-9.eExX]+',
                       re.S)
    ESC = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "\n": "\n", "a": "\a", "b": "\b",
           "f": "\f", "v": "\v"}

    def __init__(self, src):
        self.toks = [m.group(0) for m in self.TOKEN.finditer(src)
                     if not m.group(0).isspace() and not m.group(0).startswith("--")]
        self.i = 0

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else None

    def take(self, want=None):
        t = self.peek()
        if t is None or (want is not None and t != want):
            raise ValueError(f"saved variables: expected {want!r} at token {self.i}, got {t!r}")
        self.i += 1
        return t

    @classmethod
    def string(cls, tok):
        body, out, i = tok[1:-1], [], 0
        while i < len(body):
            c = body[i]
            if c == "\\" and i + 1 < len(body):
                n = body[i + 1]
                m = re.match(r"\d{1,3}", body[i + 1:])
                if m:
                    out.append(chr(int(m.group(0))))
                    i += 1 + len(m.group(0))
                    continue
                out.append(cls.ESC.get(n, n))
                i += 2
            else:
                out.append(c)
                i += 1
        return "".join(out)

    def value(self):
        t = self.take()
        if t == "{":
            return self.table()
        if t.startswith('"'):
            return self.string(t)
        if t in ("true", "false"):
            return t == "true"
        if t == "nil":
            return None
        try:
            return int(t)
        except ValueError:
            return float(t)

    def table(self):
        d, arr = {}, []
        while self.peek() != "}":
            if self.peek() == "[":
                self.take("[")
                key = self.value()
                self.take("]")
                self.take("=")
                d[key] = self.value()
            elif re.match(r"[A-Za-z_]", self.peek() or "") and self.toks[self.i + 1] == "=" and \
                    self.peek() not in ("true", "false", "nil"):
                key = self.take()
                self.take("=")
                d[key] = self.value()
            else:
                arr.append(self.value())
            if self.peek() in (",", ";"):
                self.take()
        self.take("}")
        for n, v in enumerate(arr, 1):
            d[n] = v
        return d

    def globals(self):
        out = {}
        while self.peek() is not None:
            name = self.take()
            self.take("=")
            out[name] = self.value()
        return out


def items(t):
    """A Lua array as a Python list (an empty table is {})."""
    if isinstance(t, dict):
        return [t[k] for k in sorted(k for k in t if isinstance(k, int))]
    return list(t or [])


# ---------- the dump ----------

def nums(rect):
    if not rect or rect == "-" or "?" in rect:
        return None
    try:
        left, bottom, w, h = (float(v) for v in rect.split(","))
    except ValueError:
        return None
    return left, bottom, w, h


def fields(parts):
    out = {}
    for p in parts:
        if "=" in p:
            k, v = p.split("=", 1)
            out[k] = v
    return out


def region(line):
    """key, type, flags, rect, text, k=v fields -> dict."""
    f = line.split("\t")
    while len(f) < 5:
        f.append("")
    r = {"key": f[0], "kind": f[1], "flags": f[2], "rect": nums(f[3]), "text": f[4]}
    r.update(fields(f[5:]))
    return r


def cell(line):
    """flags, width, text, rect, k=v fields -> dict (rect None in the old format)."""
    f = line.split("\t")
    while len(f) < 4:
        f.append("")
    r = {"kind": "FontString", "flags": f[0], "width": f[1], "text": f[2], "rect": nums(f[3])}
    r.update(fields(f[4:]))
    return r


def color(hexa, default="#ffffff"):
    """'rrggbbaa' -> ('#rrggbb', alpha)."""
    if not hexa or not re.fullmatch(r"[0-9a-fA-F]{8}", hexa):
        return default, 1.0
    return "#" + hexa[:6], int(hexa[6:], 16) / 255


def plain(text):
    text = re.sub(r"\|T[^|]*\|t", "#", text)
    text = re.sub(r"\|c[0-9a-fA-F]{8}|\|r|\|H[^|]*\|h|\|h|\|A[^|]*\|a", "", text)
    return text.replace("||", "|")


def short(text, n=48):
    p = plain(text).replace("\n", " ")
    return p if len(p) <= n else p[:n - 1] + "\u2026"


# ---------- drawing ----------

class Canvas:
    def __init__(self, win):
        self.wx, self.wy = float(win["x"]), float(win["y"])
        self.ww, self.wh = float(win["w"]), float(win["h"])
        self.items = []      # (level, layer, order, svg)
        self.n = 0
        self.clips = []

    def xy(self, rect):
        left, bottom, w, h = rect
        return left - self.wx + PAD, self.wy - (bottom + h) + PAD, w, h

    def add(self, level, layer, svg):
        self.n += 1
        self.items.append((level, layer, self.n, svg))

    def clip(self, x, y, w, h):
        cid = f"c{len(self.clips)}"
        self.clips.append(f'<clipPath id="{cid}"><rect x="{x:.1f}" y="{y:.1f}" width="{max(w, 0):.1f}" '
                          f'height="{max(h, 0):.1f}"/></clipPath>')
        return cid


def spans(text, default):
    """WoW markup to SVG tspans: |cffRRGGBB..|r colors, coins as colored dots, other textures as squares."""
    out, stack, i = [], [default], 0
    pattern = re.compile(r"\|c[0-9a-fA-F]{2}([0-9a-fA-F]{6})|\|r|\|T([^|]*)\|t|\|A[^|]*\|a|\|H[^|]*\|h|\|h|\|\|")
    for m in pattern.finditer(text):
        if m.start() > i:
            out.append((text[i:m.start()], stack[-1]))
        tok = m.group(0)
        if m.group(1):
            stack.append("#" + m.group(1))
        elif tok == "|r":
            if len(stack) > 1:
                stack.pop()
        elif tok == "||":
            out.append(("|", stack[-1]))
        elif m.group(2) is not None:
            for name, c in COIN.items():
                if name + "Icon" in m.group(2):
                    out.append(("\u25cf", c))
                    break
            else:
                out.append(("\u25a0", "#8a7fb0"))
        elif tok.startswith("|A"):
            out.append(("\u25a0", "#8a7fb0"))
        i = m.end()
    if i < len(text):
        out.append((text[i:], stack[-1]))
    return "".join(f'<tspan fill="{c}">{html.escape(t)}</tspan>' for t, c in out if t)


def draw_text(cv, r, level, default="#ffffff"):
    if not r["rect"] or not r["text"] or "V" not in r["flags"]:
        return
    x, y, w, h = cv.xy(r.get("box") or r["rect"])
    cx, cy, cw, ch = cv.xy(r["rect"])
    size = float(r.get("f") or max(8.0, min(h, 14) * 0.9))
    fill, _ = color(r.get("c"), default)
    j = r.get("j", "L")
    sw = float(r["sw"]) if r.get("sw") not in (None, "?") else None
    text = re.sub(r"\|T[^|]*$", "\u2026", r["text"])   # a dump before 0.3.119 cut texts at 80 characters
    lines = text.split("\n")
    # A text wider than its box that is not cut and has room for more lines wraps (by words, at the client's width).
    if sw and sw > w + 1 and "T" not in r["flags"] and h >= size * 2.2 and len(lines) == 1:
        words, per = text.split(" "), sw / max(len(plain(text)), 1)
        lines, cur = [], ""
        for word in words:
            nxt = (cur + " " + word).strip()
            if cur and len(plain(nxt)) * per > w:
                lines.append(cur)
                cur = word
            else:
                cur = nxt
        lines.append(cur)
    line_h = size * 1.15
    top = y + (h - line_h * len(lines)) / 2
    anchor, tx = {"C": ("middle", x + w / 2), "R": ("end", x + w)}.get(j, ("start", x))
    cid = cv.clip(cx - 1, cy - 2, cw + 2, ch + 4) if r.get("clip") else cv.clip(x - 1, y - 2, w + 2, h + 4)
    for n, line in enumerate(lines):
        by = top + line_h * n + size * 0.85
        fit = ""
        if sw and len(lines) == 1 and plain(line).strip():
            # As wide as the client measured it, so cut and overflow show where they are in the game.
            fit = f' textLength="{sw:.1f}" lengthAdjust="spacingAndGlyphs"'
            if j == "C":
                tx = x + w / 2
        cv.add(level, 3.5, f'<text x="{tx:.1f}" y="{by:.1f}" font-size="{size:.1f}" text-anchor="{anchor}"{fit} '
                           f'clip-path="url(#{cid})">{spans(line, fill)}</text>')
    if "T" in r["flags"]:
        cv.add(99, 0, f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" fill="none" stroke="#ff3030" '
                      f'stroke-width="1.5" stroke-dasharray="3,2"/>')


def draw_texture(cv, r, level):
    if not r["rect"] or "V" not in r["flags"] or r.get("d") == "H":
        return
    x, y, w, h = cv.xy(r["rect"])
    if w < 0.5 or h < 0.5:
        return
    layer = LAYERS.get(r.get("d"), 2)
    alpha = float(r.get("a", 1))
    tex = (r.get("tex") or "").lower()
    if r.get("ct"):
        fill, a = color(r["ct"])
        if r.get("c"):
            vc, va = color(r["c"])
            fill, a = vc if fill == "#ffffff" else fill, a * va
        cv.add(level, layer, f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" fill="{fill}" '
                             f'fill-opacity="{a * alpha:.3f}"/>')
        return
    if "button" in tex and ("panel" in tex or "-up" in tex or "-down" in tex) and "close" not in tex:
        return   # a button's own art: the button is drawn whole
    area = w * h
    if area > 0.3 * cv.ww * cv.wh:
        cv.add(level, layer, f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" fill="#141218" '
                             f'fill-opacity="{0.92 * alpha:.2f}"/>')
        return
    if not tex and not r.get("c"):
        return
    fill, a = color(r.get("c"), "#6f6888")
    if "close" in tex:
        cv.add(level, layer, f'<rect x="{x + 4:.1f}" y="{y + 4:.1f}" width="{w - 8:.1f}" height="{h - 8:.1f}" '
                             f'fill="#7a1010" stroke="#c9a640" rx="3"/><text x="{x + w / 2:.1f}" y="{y + h / 2 + 4:.1f}" '
                             f'font-size="11" fill="#ffd100" text-anchor="middle">x</text>')
        return
    cv.add(level, layer, f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" fill="{fill}" '
                         f'fill-opacity="{0.45 * a * alpha:.2f}" stroke="#9a92b8" stroke-opacity="0.5" stroke-width="0.5"/>')


def draw_frame(cv, r, level):
    if not r["rect"] or "V" not in r["flags"]:
        return
    x, y, w, h = cv.xy(r["rect"])
    kind, disabled = r["kind"], "D" in r["flags"]
    if r.get("bg"):
        fill, a = color(r["bg"])
        stroke, sa = color(r.get("bd"), "#999999")
        cv.add(level, -1, f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" fill="{fill}" '
                          f'fill-opacity="{a:.2f}" stroke="{stroke}" stroke-opacity="{sa:.2f}"/>')
    if kind == "Button" and r["text"]:
        fill = "#3a3a3a" if disabled else "#7a1010"
        cv.add(level, -0.5, f'<rect x="{x + 0.5:.1f}" y="{y + 0.5:.1f}" width="{w - 1:.1f}" height="{h - 1:.1f}" '
                            f'fill="{fill}" stroke="#c9a640" stroke-width="1" rx="3"/>')
    elif kind == "EditBox":
        cv.add(level, -0.5, f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" fill="#000000" '
                            f'fill-opacity="0.6" stroke="#808080" rx="2"/>')
        if r["text"]:
            draw_text(cv, dict(r, kind="FontString", rect=(r["rect"][0] + 4, r["rect"][1], w - 8, h), box=None), level + 0.1)
    elif kind == "CheckButton":
        s = min(w, h)
        cv.add(level, -0.5, f'<rect x="{x:.1f}" y="{y + (h - s) / 2:.1f}" width="{s:.1f}" height="{s:.1f}" '
                            f'fill="#111111" stroke="#a0a0a0" rx="2"/>')
        if "C" in r["flags"]:
            cv.add(level, -0.4, f'<text x="{x + s / 2:.1f}" y="{y + h / 2 + 5:.1f}" font-size="{s * 0.8:.1f}" '
                                f'fill="#ffd100" text-anchor="middle">\u2713</text>')
    elif kind == "Slider" and w < 30:
        cv.add(level, -0.5, f'<rect x="{x + w / 2 - 3:.1f}" y="{y:.1f}" width="6" height="{h:.1f}" fill="#000000" '
                            f'fill-opacity="0.5" rx="3"/>')


def parent_key(key):
    return key.rsplit(".", 1)[0] if "." in key else None


def intersect(a, b):
    if a is None:
        return b
    left, bottom = max(a[0], b[0]), max(a[1], b[1])
    return left, bottom, min(a[0] + a[2], b[0] + b[2]) - left, min(a[1] + a[3], b[1] + b[3]) - bottom


def clip_regions(regions):
    """Cuts each region to the frames that clip it (a scroll frame, a list): r["rect"] becomes what shows, r["box"]
    keeps the region's own rect; a region with nothing on show gets r["rect"] = None."""
    clippers = {r["key"]: r["rect"] for r in regions
                if r["rect"] and (r["kind"] == "ScrollFrame" or "K" in r["flags"])}
    for r in regions:
        r["box"] = r["rect"]
        if not r["rect"] or not clippers:
            continue
        area, k = None, r["key"]
        while (k := parent_key(k)) is not None:
            if k in clippers:
                area = intersect(area, clippers[k])
        if area is None:
            continue
        shown = intersect(area, r["rect"])
        r["rect"] = shown if shown[2] > 0.5 and shown[3] > 0.5 else None
        r["clip"] = area
    return regions


def draw(name, win, dump):
    cv = Canvas(win)
    regions = clip_regions([region(line) for line in items(win.get("regions"))])
    levels = {}
    for r in regions:
        if r["kind"] not in ("FontString", "Texture"):
            # Child frames draw over their parent's regions: the frame level, or the depth where there is none.
            levels[r["key"]] = float(r["fl"]) if r.get("fl") not in (None, "?") else r["key"].count(".")
    lists = win.get("lists") or {}
    new_format = "screen" in dump
    for r in regions:
        if "S" not in r["flags"]:
            continue
        if r["kind"] == "FontString":
            draw_text(cv, r, levels.get(parent_key(r["key"]), 0))
        elif r["kind"] == "Texture":
            draw_texture(cv, r, levels.get(parent_key(r["key"]), 0))
        else:
            draw_frame(cv, r, levels.get(r["key"], 0))
    by_key = {r["key"]: r for r in regions}
    for key, info in lists.items():
        lr = by_key.get(key)
        if not lr or not lr["rect"] or "V" not in lr["flags"]:
            continue
        level = levels.get(key, 0) + 0.5
        if new_format:
            for row in items(info.get("rows")):
                rect = nums(row.get("rect"))
                if rect and row.get("n", 0) % 2 == 0:
                    x, y, w, h = cv.xy(rect)
                    cv.add(level, 0, f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" fill="#ffffff" '
                                     f'fill-opacity="0.035"/>')
                for c in items(row.get("cells")):
                    c = cell(c)
                    if "S" in c["flags"]:
                        draw_text(cv, c, level)
                for p in items(row.get("parts")):
                    p = region(p)
                    if p["kind"] == "Texture":
                        draw_texture(cv, dict(p, tex=p.get("tex") or "icon"), level)
                    else:
                        draw_frame(cv, p, level + 0.2)
                        for q in regions_of_part(p):
                            draw_text(cv, q, level + 0.3)
        else:
            old_list(cv, info, lr, level)
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{cv.ww + 2 * PAD:.0f}" '
           f'height="{cv.wh + 2 * PAD + FOOT:.0f}" font-family="DejaVu Sans Condensed, DejaVu Sans, sans-serif" xml:space="preserve">',
           f'<defs>{"".join(cv.clips)}</defs>',
           '<rect width="100%" height="100%" fill="#3a3f44"/>',
           f'<rect x="{PAD}" y="{PAD}" width="{cv.ww:.1f}" height="{cv.wh:.1f}" fill="#000000" fill-opacity="0.35"/>']
    svg += [s for *_, s in sorted(cv.items, key=lambda t: (t[0], t[1], t[2]))]
    svg.append(f'<rect x="{PAD}" y="{PAD}" width="{cv.ww:.1f}" height="{cv.wh:.1f}" fill="none" stroke="#c9a640" '
               f'stroke-opacity="0.6"/>')
    view = f', view {win["view"]}' if win.get("view") else ""
    svg.append(f'<text x="{PAD}" y="{cv.wh + 2 * PAD + 12:.1f}" font-size="11" fill="#d0d0d0">{html.escape(name)}'
               f'{html.escape(view)}, {win["w"]} x {win["h"]}, Salvager {html.escape(str(dump.get("version")))}'
               f' (red dashes: text cut)</text>')
    svg.append("</svg>")
    return "\n".join(svg)


def regions_of_part(p):
    """A row's button: its text as a centered line (its font string is not in the dump)."""
    if p["kind"] == "Button" and p["text"] and p["rect"]:
        return [dict(p, kind="FontString", j="C", flags=p["flags"], sw=None)]
    return []


def old_list(cv, info, lr, level):
    """The 0.3.114-0.3.118 dump: titles and the first row only, laid out from the widths."""
    x0, y0, w, h = cv.xy(lr["rect"])
    cx, widths = x0 + 4, []
    for hd in items(info.get("headers")):
        title, shown, cw = (hd.split("\t") + ["", "", "0"])[:3]
        if shown != "S":
            widths.append(None)
            continue
        cw = float(cw)
        cv.add(level, 3, f'<text x="{cx:.1f}" y="{y0 + 15:.1f}" font-size="10" fill="#ffd100">'
                         f'{html.escape(plain(title))}</text>')
        widths.append((cx, cw))
        cx += cw + 6
    for i, c in enumerate(items(info.get("row1"))):
        c = cell(c)
        if i < len(widths) and widths[i] and "S" in c["flags"]:
            cv.add(level, 3, f'<text x="{widths[i][0]:.1f}" y="{y0 + 37:.1f}" font-size="10">'
                             f'{spans(c["text"], "#ffffff")}</text>')


# ---------- problems ----------

def box(r):
    """The part of a region that shows: a text's own extent (its width as measured, its line height)."""
    left, bottom, w, h = r["rect"]
    if r["kind"] == "FontString":
        sw = float(r["sw"]) if r.get("sw") not in (None, "?") else w
        tw = min(sw, w)
        j = r.get("j", "L")
        left = left + (w - tw) / 2 if j == "C" else left + w - tw if j == "R" else left
        size = float(r.get("f") or h)
        if h > size * 1.4 and sw <= w:
            bottom, h = bottom + (h - size) / 2, size
        w = tw
    return left, bottom, w, h


def overlap(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return min(ax + aw, bx + bw) - max(ax, bx), min(ay + ah, by + bh) - max(ay, by)


def related(a, b):
    return a == b or a.startswith(b + ".") or b.startswith(a + ".")


def problems(name, win, dump):
    out = []
    wx, wy, ww, wh = float(win["x"]), float(win["y"]), float(win["w"]), float(win["h"])
    wb = wy - wh
    screen = dump.get("screen") or {}
    try:
        sw, sh = float(screen["w"]), float(screen["h"])
        k = float(win.get("eff") or 1) / float(screen.get("eff") or 1)
        if wx * k < -1 or wb * k < -1 or (wx + ww) * k > sw + 1 or wy * k > sh + 1:
            # Allowed (SDD 98) while 40 px of the title bar stay on the screen; a problem past that.
            left, right, top = wx * k, (wx + ww) * k, wy * k
            bad = right < 40 - 1 or left > sw - 40 + 1 or top > sh + 1 or top - 24 < -1
            out.append(f"window {'past its clamp' if bad else 'partly off the screen (allowed)'}: "
                       f"{wx * k:.0f},{wb * k:.0f} to {(wx + ww) * k:.0f},{wy * k:.0f}"
                       f" on {sw:.0f} x {sh:.0f}")
    except (KeyError, ValueError, TypeError):
        pass
    if win.get("dropped"):
        out.append("regions dropped from the dump (size bound): only the lists are checked")
    regions = clip_regions([region(line) for line in items(win.get("regions"))])
    visible = [r for r in regions if "V" in r["flags"] and r["rect"] and r["kind"] != "Texture"]
    for r in visible:
        if r["kind"] == "FontString" and r["text"]:
            text = short(r["text"])
            if "T" in r["flags"]:
                out.append(f"text cut: {r['key']}: \"{text}\"")
            elif r.get("sw") not in (None, "?") and float(r["sw"]) > r["rect"][2] + 1 and \
                    r["rect"][3] < float(r.get("f") or 10) * 2.2:
                out.append(f"text wider than its box ({float(r['sw']):.0f} > {r['rect'][2]:.0f}): {r['key']}: \"{text}\"")
        left, bottom, w, h = r["rect"]
        if r["key"].endswith(".CloseButton"):
            continue   # the window template puts it over the border corner
        if w > 0 and h > 0 and (left < wx - 1 or bottom < wb - 1 or left + w > wx + ww + 1 or bottom + h > wy + 1):
            out.append(f"outside the window: {r['key']} ({r['kind']}) at {left - wx:.0f},{wy - bottom - h:.0f} "
                       f"size {w:.0f} x {h:.0f}")
    # Controls and texts that cover each other (a region and what is inside it are not counted). A button without
    # text counts by its art (its textures outside the highlight layer): a bare click area over a label is not drawn.
    art = {}
    for r in regions:
        if r["kind"] == "Texture" and "V" in r["flags"] and r["rect"] and r.get("d") != "H" and r["rect"][2] > 0:
            art.setdefault(parent_key(r["key"]), []).append(r["rect"])
    controls = []
    for r in visible:
        if r["kind"] == "FontString" and plain(r["text"]).strip():
            controls.append(r)
        elif r["kind"] in ("Button", "EditBox", "CheckButton") and r["rect"][2] > 1:
            if r["kind"] == "Button" and not r["text"]:
                rects = art.get(r["key"])
                if not rects:
                    continue
                x0, y0 = min(q[0] for q in rects), min(q[1] for q in rects)
                x1, y1 = max(q[0] + q[2] for q in rects), max(q[1] + q[3] for q in rects)
                r = dict(r, rect=(x0, y0, x1 - x0, y1 - y0))
            controls.append(r)
    for i, a in enumerate(controls):
        for b in controls[i + 1:]:
            if related(a["key"], b["key"]) or parent_key(a["key"]) is None:
                continue
            if a["kind"] == "FontString" and b["kind"] == "FontString" and a["text"] == b["text"]:
                continue
            dx, dy = overlap(box(a), box(b))
            if dx > 2 and dy > 2:
                out.append(f"overlap {dx:.0f} x {dy:.0f}: {a['key']} ({a['kind']} \"{short(a['text'], 20)}\") and "
                           f"{b['key']} ({b['kind']} \"{short(b['text'], 20)}\")")
    by_key = {r["key"]: r for r in regions}
    for key, info in (win.get("lists") or {}).items():
        lr = by_key.get(key)
        if lr is not None and "V" not in lr["flags"]:
            continue
        needed, w = info.get("needed"), info.get("w")
        if needed not in (None, "?") and w not in (None, "?") and float(needed) > float(w) + 0.5:
            out.append(f"list narrower than its columns: {key} is {float(w):.0f}, its columns need {float(needed):.0f}")
        titles = [h.split("\t") for h in items(info.get("headers"))]
        for t in titles:
            if len(t) > 3 and t[1] == "S" and t[3] == "T":
                out.append(f"title cut: {key}: \"{short(t[0])}\"")
        cut, wide = {}, {}
        rows = items(info.get("rows"))
        for row in rows:
            for col, c in enumerate(items(row.get("cells")), 1):
                c = cell(c)
                if "S" not in c["flags"] or not c["text"]:
                    continue
                if "T" in c["flags"]:
                    cut.setdefault(col, []).append((row.get("n"), c["text"]))
                elif c.get("sw") not in (None, "?") and c["width"] not in ("", "?") and \
                        float(c["sw"]) > float(c["width"]) + 1:
                    wide.setdefault(col, []).append((row.get("n"), c["text"]))
        for what, found in (("cut", cut), ("wider than the cell", wide)):
            for col, hits in sorted(found.items()):
                title = titles[col - 1][0] if col <= len(titles) else str(col)
                n, text = hits[0]
                out.append(f"{key} column \"{plain(title)}\": {len(hits)} of {len(rows)} rows {what} "
                           f"(row {n}: \"{short(text, 36)}\")")
    out += control_problems(regions, win)
    return out


# The kinds of control (k= in the dump, UI.md Controls) a row may hold.
ROW_KINDS = {"tabrow": ("tab",), "subtabrow": ("subtab",)}
RED_ART = ("UI-Panel-Button", "RedButton", "UIPanelButton")


def control_problems(regions, win):
    """UI.md Controls: (1) a row of tabs or subtabs holds tabs only; (2) a statement's amounts end at the panel's
    right edge; (3) a tab, a subtab or a dropdown never has the red button's art."""
    out = []
    by_key = {r["key"]: r for r in regions}
    shown = [r for r in regions if "V" in r["flags"] and r["rect"]]
    for row in shown:
        allowed = ROW_KINDS.get(row.get("k"))
        if not allowed:
            continue
        rx, ry, rw, rh = row["rect"]
        for r in shown:
            if r is row or r["kind"] == "Texture":
                continue
            if r["kind"] == "FontString" and not plain(r["text"]).strip():
                continue
            # What is inside a tab (its text, its art) belongs to it.
            k, owner = r["key"], None
            while k is not None:
                if by_key.get(k, {}).get("k") in ("tab", "subtab"):
                    owner = k
                    break
                k = parent_key(k)
            if owner is not None:
                continue
            if r["kind"] not in ("Button", "CheckButton", "EditBox", "FontString", "Frame") or \
                    (r["kind"] == "Frame" and not r.get("k")):
                continue
            inside = r["key"].startswith(row["key"] + ".")
            x, y, w, h = box(r)
            cy = y + h / 2
            on_row = ry <= cy <= ry + rh and x < rx + rw and x + w > rx
            if (inside or on_row) and r.get("k") not in allowed and not r["key"].startswith(row["key"].rsplit(".", 1)[0] + ".CloseButton"):
                out.append(f"{row['k']} holds a {r.get('k') or r['kind']}: {r['key']} \"{short(r['text'], 24)}\"")
    for r in shown:
        if r.get("k") in ("tab", "subtab", "dropdown"):
            for q in regions:
                if q["kind"] == "Texture" and q["key"].startswith(r["key"] + ".") and \
                        any(a in (q.get("tex") or "") for a in RED_ART):
                    out.append(f"{r['k']} with the red button look: {r['key']} \"{short(r['text'], 24)}\"")
                    break
    for key, info in (win.get("lists") or {}).items():
        if info.get("kind") != "statement":
            continue
        lr = by_key.get(key)
        if not lr or not lr["rect"] or "V" not in lr["flags"]:
            continue
        right = lr["rect"][0] + lr["rect"][2]
        ends = []
        for row in items(info.get("rows")):
            cells = [cell(c) for c in items(row.get("cells"))]
            filled = [c for c in cells if "S" in c["flags"] and plain(c["text"]).strip() and c["rect"]]
            if len(filled) >= 2:
                c = filled[-1]
                ends.append(c["rect"][0] + c["rect"][2])
        if ends and right - max(ends) > 30:
            out.append(f"statement amounts not at the panel's right edge: {key} ends {right - max(ends):.0f} px "
                       f"before it")
    return out


# ---------- main ----------

def png(names):
    r = subprocess.run(["docker", "build", "-q", "-t", IMAGE, os.path.join(ROOT, "scripts", "layout")],
                       capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"docker build failed: {r.stderr.strip()}")
    script = " && ".join(f"rsvg-convert -z 1.5 -o /out/{n}.png /out/{n}.svg" for n in names)
    r = subprocess.run(["docker", "run", "--rm", "-u", f"{os.getuid()}:{os.getgid()}", "-e", "HOME=/tmp",
                        "-v", f"{OUT}:/out", IMAGE, "sh", "-c", script], capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"rsvg-convert failed: {r.stderr.strip()}")


def main():
    args = sys.argv[1:]
    if args[:1] == ["--file"] and len(args) == 2:
        path = args[1]
    elif not args:
        path = fetch()
    else:
        fail("usage: layout.py [--file Salvager.lua]")
    with open(path, encoding="utf-8", errors="replace") as f:
        saved = Lua(f.read()).globals()
    dump = (saved.get("SalvagerDB") or {}).get("layout")
    if not isinstance(dump, dict):
        fail("no layout dump in the saved variables: /reload once with Salvager 0.3.114 or later")
    os.makedirs(OUT, exist_ok=True)
    for old in os.listdir(OUT):
        if old.endswith((".svg", ".png")):
            os.remove(os.path.join(OUT, old))
    windows = dump.get("windows") or {}
    print(f"dump: Salvager {dump.get('version')}, {dump.get('entries', '?')} regions, {dump.get('size', '?')} bytes"
          + (" (region limit reached)" if dump.get("full") else ""))
    shown = sorted(n for n, w in windows.items() if isinstance(w, dict) and w.get("shown"))
    for n, w in sorted(windows.items()):
        if isinstance(w, dict) and w.get("error"):
            print(f"{n}: dump failed in the game: {w['error']}")
    if not shown:
        print("no Salvager window was open at the last /reload or logout: open one, /reload, run make layout again")
        return
    for n in shown:
        with open(os.path.join(OUT, f"{n}.svg"), "w", encoding="utf-8") as f:
            f.write(draw(n, windows[n], dump))
    png(shown)
    for n in shown:
        found = problems(n, windows[n], dump)
        print(f"\n{n} ({windows[n].get('w')} x {windows[n].get('h')}"
              + (f", view {windows[n]['view']}" if windows[n].get("view") else "") + f"): "
              + (f"{len(found)} problems" if found else "no problems")
              + f" -> {os.path.relpath(os.path.join(OUT, n + '.png'), ROOT)}")
        for p in found[:MAX_LISTED]:
            print(f"  - {p}")
        if len(found) > MAX_LISTED:
            print(f"  ... and {len(found) - MAX_LISTED} more")


if __name__ == "__main__":
    main()
