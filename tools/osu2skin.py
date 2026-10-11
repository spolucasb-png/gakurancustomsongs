#!/usr/bin/env python3
"""
osu!mania skin -> GakuranChart skin pack converter.

Reads an osu! skin folder (skin.ini [Mania] Keys:N section, lazer-style
NoteImage*/KeyImage* references with stable-name fallback) and produces a
GakuranCharts/Skins/<slug>/ pack:

    head.png       tap note image (single image for all lanes)
    headHold.png   optional: long-note head (skin.ini NoteImage<n>H)
    tap<n>.png     optional: per-lane tap art for lanes whose NoteImage<n>
                   differs from the base lane (e.g. outer `lefto` vs inner
                   `left`); other lanes fall back to head.png (manifest.taps)
    receptor.png   receptor (key) image
    receptorPressed.png  optional: pressed receptor (skin.ini KeyImage<n>D)
    tail.png       composited long-note sprite: body + end cap,
                   drawn stretched by the engine via SliceCenter
    manifest.json  asset names + tail sprite metrics

Pure stdlib (no Pillow): PNG decode/encode for 8-bit RGB/RGBA palettes.

Usage:
    python tools/osu2skin.py "C:/path/to/osu skin" --out <workspace>/GakuranCharts/Skins
                             [--keys 4] [--lane 2] [--name "My Skin"]
"""

import argparse
import json
import os
import re
import struct
import sys
import zlib


# ---------------------------------------------------------------- PNG codec

def png_decode(data: bytes):
    """Return (width, height, rgba_bytes). 8-bit RGB/RGBA/palette, non-interlaced."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG file")
    pos = 8
    idat = bytearray()
    plte = None
    trns = None
    w = h = None
    bitdepth = colortype = interlace = None
    while pos + 8 <= len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            w, h, bitdepth, colortype, _comp, _filt, interlace = struct.unpack(">IIBBBBB", chunk)
        elif ctype == b"PLTE":
            plte = chunk
        elif ctype == b"tRNS":
            trns = chunk
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break
    if w is None:
        raise ValueError("PNG missing IHDR")
    if bitdepth != 8 or interlace != 0:
        raise ValueError(f"unsupported PNG (bitdepth={bitdepth}, interlace={interlace})")
    if colortype not in (0, 2, 3, 4, 6):
        raise ValueError(f"unsupported PNG colortype {colortype}")

    bpp = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colortype]
    stride = w * bpp
    raw = zlib.decompress(bytes(idat))

    # unfilter scanlines
    lines = []
    prev = bytearray(stride)
    p = 0
    for _y in range(h):
        f = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pa = abs(b - c)
                pb = abs(a - c)
                pc = abs(a + b - 2 * c)
                if pa <= pb and pa <= pc:
                    pr = a
                elif pb <= pc:
                    pr = b
                else:
                    pr = c
                line[i] = (line[i] + pr) & 255
        elif f != 0:
            raise ValueError(f"unknown PNG filter {f}")
        lines.append(line)
        prev = line

    out = bytearray(w * h * 4)
    for y, line in enumerate(lines):
        o = y * w * 4
        if colortype == 6:
            out[o:o + w * 4] = line
        elif colortype == 2:
            for x in range(w):
                out[o + x * 4:o + x * 4 + 3] = line[x * 3:x * 3 + 3]
                out[o + x * 4 + 3] = 255
        elif colortype == 0:
            for x in range(w):
                g = line[x]
                out[o + x * 4:o + x * 4 + 4] = bytes((g, g, g, 255))
        elif colortype == 4:
            for x in range(w):
                g = line[x * 2]
                a = line[x * 2 + 1]
                out[o + x * 4:o + x * 4 + 4] = bytes((g, g, g, a))
        elif colortype == 3:
            if plte is None:
                raise ValueError("palette PNG missing PLTE")
            for x in range(w):
                idx = line[x]
                out[o + x * 4:o + x * 4 + 3] = plte[idx * 3:idx * 3 + 3]
                out[o + x * 4 + 3] = trns[idx] if (trns and idx < len(trns)) else 255
    return w, h, out


def png_encode(w: int, h: int, rgba: bytes) -> bytes:
    def chunk(ctype: bytes, payload: bytes) -> bytes:
        c = ctype + payload
        return struct.pack(">I", len(payload)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)  # filter: none
        raw += rgba[y * stride:(y + 1) * stride]
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
            + chunk(b"IEND", b""))


def resize_nearest(rgba: bytes, sw: int, sh: int, dw: int, dh: int) -> bytes:
    out = bytearray(dw * dh * 4)
    for y in range(dh):
        sy = min(sh - 1, y * sh // dh)
        for x in range(dw):
            sx = min(sw - 1, x * sw // dw)
            s = (sy * sw + sx) * 4
            d = (y * dw + x) * 4
            out[d:d + 4] = rgba[s:s + 4]
    return out


def flip_vertical(rgba: bytes, w: int, h: int) -> bytes:
    out = bytearray(len(rgba))
    stride = w * 4
    for y in range(h):
        out[(h - 1 - y) * stride:(h - y) * stride] = rgba[y * stride:(y + 1) * stride]
    return out


def alpha_bbox(rgba: bytes, w: int, h: int, threshold: int = 8):
    minx, miny, maxx, maxy = w, h, -1, -1
    for y in range(h):
        row = y * w * 4
        for x in range(w):
            if rgba[row + x * 4 + 3] > threshold:
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y
    if maxx < 0:
        return None
    return minx, miny, maxx + 1, maxy + 1


def fit_to_frame(rgba: bytes, w: int, h: int, aspect: float = 1.0, box=None):
    """Crop to the alpha bounding box and center on a canvas matching the
    engine's frame aspect (the highway paints notes/receptors with ScaleType
    Fit, so osu skins' oversized transparent canvases render tiny).
    `box` overrides the crop rectangle (minx, miny, maxx, maxy); see
    shared_box() for why alternate-state sprites reuse their base sprite's."""
    if box is None:
        box = alpha_bbox(rgba, w, h)
    if box is None:
        return w, h, rgba
    minx, miny, maxx, maxy = box
    aw, ah = maxx - minx, maxy - miny
    cropped = bytearray(aw * ah * 4)
    for y in range(ah):
        src = ((miny + y) * w + minx) * 4
        cropped[y * aw * 4:(y + 1) * aw * 4] = rgba[src:src + aw * 4]
    # target canvas: aspect (w/h) with the art at max dimension
    if aw / max(1, ah) >= aspect:
        cw, ch = aw, max(ah, int(round(aw / aspect)))
    else:
        ch, cw = ah, max(aw, int(round(ah * aspect)))
    canvas = bytearray(cw * ch * 4)
    ox, oy = (cw - aw) // 2, (ch - ah) // 2
    for y in range(ah):
        dst = ((oy + y) * cw + ox) * 4
        canvas[dst:dst + aw * 4] = cropped[y * aw * 4:(y + 1) * aw * 4]
    return cw, ch, canvas


def shared_box(own, ref, tol: int = 2):
    """Crop box for an alternate-state sprite (hold head, pressed key).

    osu draws a skin's normal and alternate images on the same canvas, so
    their art keeps its relative position and scale. The base sprite
    (tap head / resting receptor) is cropped to its own alpha box; when the
    alternate image has the same source size and its art fits that box
    (within `tol` px), crop it with the SAME box so both frame identically
    and nothing visibly jumps in size or position when the engine swaps
    them. Otherwise return None: the caller crops to the alternate's own
    box, which never clips art."""
    if own is None or ref is None:
        return None
    if (own[0] >= ref[0] - tol and own[1] >= ref[1] - tol
            and own[2] <= ref[2] + tol and own[3] <= ref[3] + tol):
        return ref
    return None


# ------------------------------------------------------------- skin.ini

def parse_ini(path: str):
    """Return list of (section_name, {key: value}); keeps duplicate sections."""
    sections = []
    cur = None
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.split("//")[0].split(";")[0].strip()
            if not line:
                continue
            if line.startswith("[") and line.endswith("]"):
                cur = (line[1:-1].strip(), {})
                sections.append(cur)
            elif ":" in line and cur is not None:
                k, v = line.split(":", 1)
                cur[1][k.strip()] = v.strip()
    return sections


def pick_mania(sections, keys: int):
    for name, kv in sections:
        if name.lower() == "mania" and kv.get("Keys", "").strip() == str(keys):
            return kv
    for name, kv in sections:
        if name.lower() == "mania":
            return kv
    return {}


def ci_lookup(base: str, name: str, exts=(".png",)) -> str:
    """Case-insensitive file lookup; prefers @2x variants."""
    if not os.path.isdir(base):
        return None
    entries = {e.lower(): e for e in os.listdir(base)}
    for ext in exts:
        for candidate in (name + "@2x" + ext, name + ext, name.lower() + "@2x" + ext, name.lower() + ext):
            real = entries.get(candidate.lower())
            if real:
                return os.path.join(base, real)
    return None


def resolve_ref(skin_dir: str, ref: str):
    """Resolve a skin.ini image reference like '4K\\lefto' (no extension)."""
    if not ref or ref.strip().lower() in ("blank", "none"):
        return None
    parts = ref.replace("/", "\\").split("\\")
    cur = skin_dir
    for part in parts[:-1]:
        match = ci_lookup(cur, part, exts=("",))
        if not match or not os.path.isdir(match):
            # try as folder name case-insensitively
            found = None
            if os.path.isdir(cur):
                for e in os.listdir(cur):
                    if e.lower() == part.lower() and os.path.isdir(os.path.join(cur, e)):
                        found = os.path.join(cur, e)
                        break
            if not found:
                return None
            cur = found
        else:
            cur = match
    return ci_lookup(cur, parts[-1])


# ------------------------------------------------------------------ main

def convert_osu_skin(skin_dir: str, out: str, keys: int = 4, lane=None,
                     aspect: float = 1.0, name=None) -> str:
    """Convert an osu!mania skin folder into a GakuranChart pack; return out_dir.

    Importable core of main() (moved verbatim): unified convert_skin.py calls
    this, qua2skin and etterna2skin share the same shape.
    """
    sections = parse_ini(os.path.join(skin_dir, "skin.ini"))
    mania = pick_mania(sections, keys)
    general = next((kv for n, kv in sections if n.lower() == "general"), {})

    lane = lane or (keys // 2 + keys % 2)  # 1-based middle lane
    i = lane - 1

    def mania_ref(*names):
        for n in names:
            if n in mania and mania[n].strip():
                return mania[n].strip()
        return None

    head_ref = mania_ref(f"NoteImage{i}", f"NoteImage{i}H")
    body_ref = mania_ref(f"NoteImage{i}L")
    cap_ref = mania_ref(f"NoteImage{i}T")
    receptor_ref = mania_ref(f"KeyImage{i}")
    head_hold_ref = mania_ref(f"NoteImage{i}H")
    receptor_down_ref = mania_ref(f"KeyImage{i}D")

    # stable-name fallbacks
    head_path = resolve_ref(skin_dir, head_ref) if head_ref else None
    if not head_path:
        head_path = ci_lookup(skin_dir, f"mania-note{min(lane, 10)}")
    receptor_path = resolve_ref(skin_dir, receptor_ref) if receptor_ref else None
    if not receptor_path:
        receptor_path = ci_lookup(skin_dir, f"mania-key{min(lane, 10)}")
    body_path = resolve_ref(skin_dir, body_ref) if body_ref else None
    cap_path = resolve_ref(skin_dir, cap_ref) if cap_ref else None

    # optional extras (stable-name fallbacks mirror the tap/receptor lookups)
    head_hold_path = resolve_ref(skin_dir, head_hold_ref) if head_hold_ref else None
    if not head_hold_path:
        head_hold_path = ci_lookup(skin_dir, f"mania-note{min(lane, 10)}H")
    receptor_down_path = resolve_ref(skin_dir, receptor_down_ref) if receptor_down_ref else None
    if not receptor_down_path:
        receptor_down_path = ci_lookup(skin_dir, f"mania-key{min(lane, 10)}D")

    if not head_path:
        print("error: could not resolve a tap-note image (skin.ini NoteImage*, mania-note*)", file=sys.stderr)
        sys.exit(1)
    if not receptor_path:
        print("warning: no receptor image found, reusing the tap note image", file=sys.stderr)
        receptor_path = head_path
    if not body_path:
        print("warning: no LN body image (NoteImage*L); holds will use the tap image as a plain bar", file=sys.stderr)
        body_path = head_path
    if not cap_path:
        print("warning: no LN end cap (NoteImage*T); hold tails will have no end cap", file=sys.stderr)

    with open(head_path, "rb") as f:
        head_data = f.read()
    with open(receptor_path, "rb") as f:
        receptor_data = f.read()

    # head + receptor: crop to the art's alpha bounding box and center on a
    # frame-aspect canvas, otherwise Fit renders osu canvases tiny
    hw, hh, head_px = png_decode(head_data)
    head_src = (hw, hh, alpha_bbox(head_px, hw, hh))
    hw, hh, head_px = fit_to_frame(head_px, hw, hh, aspect, head_src[2])
    head_out = png_encode(hw, hh, head_px)

    rw, rh, rec_px = png_decode(receptor_data)
    rec_src = (rw, rh, alpha_bbox(rec_px, rw, rh))
    rw, rh, rec_px = fit_to_frame(rec_px, rw, rh, aspect, rec_src[2])
    rec_out = png_encode(rw, rh, rec_px)

    def fit_optional(path, label, base_src):
        """Crop/pad an optional alternate-state image like its base sprite.
        base_src = (w, h, alpha box) of the base image it replaces. Returns
        (PNG bytes, framing note), or None when the image can't be read
        (the pack still builds without it)."""
        try:
            with open(path, "rb") as f:
                ow, oh, opx = png_decode(f.read())
        except (ValueError, OSError, IndexError, zlib.error, struct.error) as e:
            print(f"warning: could not read {label} ({os.path.basename(path)}): {e}; skipping",
                  file=sys.stderr)
            return None
        own_box = alpha_bbox(opx, ow, oh)
        box, note = own_box, "own alpha box"
        if own_box is None:
            print(f"warning: {label} ({os.path.basename(path)}) is fully transparent; skipping",
                  file=sys.stderr)
            return None
        if (ow, oh) == (base_src[0], base_src[1]):
            ref = shared_box(own_box, base_src[2])
            if ref is not None:
                box, note = ref, "same crop as its base sprite"
            else:
                print(f"warning: {label} art extends past its base sprite's bounds; "
                      f"cropped to its own box (its size may differ slightly in game)",
                      file=sys.stderr)
        ow, oh, opx = fit_to_frame(opx, ow, oh, aspect, box)
        return png_encode(ow, oh, opx), note

    # Identical-to-base refs (e.g. NoteImage<n>H == NoteImage<n>) add nothing.
    def same_file(a, b):
        return os.path.normcase(os.path.abspath(a)) == os.path.normcase(os.path.abspath(b))

    hold_head_out, hold_head_note = None, ""
    if head_hold_path and not same_file(head_hold_path, head_path):
        res = fit_optional(head_hold_path, "hold head", head_src)
        if res:
            hold_head_out, hold_head_note = res
    receptor_down_out, receptor_down_note = None, ""
    if receptor_down_path and not same_file(receptor_down_path, receptor_path):
        res = fit_optional(receptor_down_path, "pressed receptor", rec_src)
        if res:
            receptor_down_out, receptor_down_note = res

    # Per-lane tap variants (e.g. outer lanes use `lefto` while the base
    # lane uses `left`). Only lanes whose source file differs from the base
    # lane's get their own sprite, framed like the base head so lanes never
    # visibly jump in size. Keys are 1-based lane numbers (the engine's).
    lane_taps = {}
    for j in range(keys):
        lj_ref = mania.get(f"NoteImage{j}", "").strip()
        lj_path = resolve_ref(skin_dir, lj_ref) if lj_ref else None
        if not lj_path:
            lj_path = ci_lookup(skin_dir, f"mania-note{min(j + 1, 10)}")
        if lj_path and not same_file(lj_path, head_path):
            res = fit_optional(lj_path, f"lane {j + 1} tap", head_src)
            if res:
                lane_taps[j + 1] = res
    bw, bh, body_px = png_decode(open(body_path, "rb").read())

    # Composite tail sprite: [cap][body][cap-flipped].
    # RhythmView pins the tail label at the note center and flips its anchor
    # per scroll direction ((0.5,1) growing up in downscroll, (0.5,0) growing
    # down in upscroll), so the image's top/bottom ends swap meaning between
    # directions - the end cap must therefore sit at BOTH ends (the game's
    # own tail sprites are symmetric for the same reason). The body band in
    # the middle is the SliceCenter stretch zone.
    canvas_h = bh
    cap_h = 0
    cap_px = None
    slice_y1, slice_y2 = 0, max(1, bh)
    if cap_path:
        cap_w, cap_h, cap_px = png_decode(open(cap_path, "rb").read())
        if cap_w != bw:
            cap_px = resize_nearest(cap_px, cap_w, cap_h, bw, cap_h)
        slice_y1, slice_y2 = cap_h, cap_h + bh
        canvas_h = cap_h + bh + cap_h
    row = bw * 4
    canvas = bytearray(bw * canvas_h * 4)
    if cap_px:
        # The skin's cap art has its rounded edge toward the sprite's bottom;
        # the hold-end side of the label (its TOP in downscroll) needs the
        # flipped copy so both tips face outward. Verified in-game.
        canvas[0:cap_h * row] = flip_vertical(cap_px, bw, cap_h)
        canvas[cap_h * row:(cap_h + bh) * row] = body_px
        canvas[(cap_h + bh) * row:(cap_h * 2 + bh) * row] = cap_px
    else:
        canvas[0:bh * row] = body_px

    # output pack
    name = name or general.get("Name") or os.path.basename(os.path.normpath(skin_dir))
    slug = re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").lower() or "skin"
    shape_key = "GK_" + re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_")
    out_dir = os.path.join(out, slug)
    os.makedirs(out_dir, exist_ok=True)

    with open(os.path.join(out_dir, "head.png"), "wb") as f:
        f.write(head_out)
    with open(os.path.join(out_dir, "receptor.png"), "wb") as f:
        f.write(rec_out)
    with open(os.path.join(out_dir, "tail.png"), "wb") as f:
        f.write(png_encode(bw, canvas_h, canvas))
    wanted = {"head.png", "receptor.png", "tail.png", "manifest.json"}
    for fname, data in (("headHold.png", hold_head_out), ("receptorPressed.png", receptor_down_out),
                        *((f"tap{lane}.png", png) for lane, (png, _note) in sorted(lane_taps.items()))):
        target = os.path.join(out_dir, fname)
        wanted.add(fname)
        if data is not None:
            with open(target, "wb") as f:
                f.write(data)
        elif os.path.isfile(target):
            os.remove(target)  # stale extra from an earlier run of this pack
    # stale per-lane taps from an earlier run (lane art since unified)
    for entry in os.listdir(out_dir):
        if entry.startswith("tap") and entry.endswith(".png") and entry not in wanted:
            os.remove(os.path.join(out_dir, entry))

    manifest = {
        "name": name,
        "shapeKey": shape_key,
        "head": "head.png",
        "receptor": "receptor.png",
        "tail": "tail.png",
        "tailW": bw,
        "tailH": canvas_h,
        "slice": [bw // 2 - 1, slice_y1, bw // 2 + 1, slice_y2],
        "source": {"skinDir": skin_dir, "keys": keys, "lane": lane},
    }
    if hold_head_out is not None:
        manifest["headHold"] = "headHold.png"
    if receptor_down_out is not None:
        manifest["receptorPressed"] = "receptorPressed.png"
    if lane_taps:
        manifest["taps"] = {str(lane): f"tap{lane}.png" for lane in sorted(lane_taps)}
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)

    print(f"pack:    {out_dir}")
    print(f"name:    {name}")
    print(f"shape:   {shape_key}")
    print(f"head:    {os.path.basename(head_path)} ({hw}x{hh})")
    print(f"holdhead:{os.path.basename(head_hold_path) + ' (' + hold_head_note + ')' if hold_head_out is not None else '-'}")
    print(f"pressed: {os.path.basename(receptor_down_path) + ' (' + receptor_down_note + ')' if receptor_down_out is not None else '-'}")
    if lane_taps:
        for lane in sorted(lane_taps):
            _png, note = lane_taps[lane]
            print(f"tap{lane}:   lane {lane} ({note})")
    else:
        print("taps:    - (all lanes share the base head)")
    print(f"receptor:{os.path.basename(receptor_path)}")
    print(f"tail:    body {bw}x{bh}" + (f" + caps {cap_h}px each" if cap_px else "") + f" -> {bw}x{canvas_h}, slice [{bw // 2 - 1}, {slice_y1}, {bw // 2 + 1}, {slice_y2}]")
    return out_dir


def main():
    ap = argparse.ArgumentParser(description="Convert an osu!mania skin into a GakuranChart skin pack")
    ap.add_argument("skin_dir", help="osu! skin folder (contains skin.ini)")
    ap.add_argument("--out", required=True, help="output Skins directory")
    ap.add_argument("--keys", type=int, default=4, help="key-count section to use (default 4)")
    ap.add_argument("--lane", type=int, default=None,
                    help="1-based lane for the tap/receptor image when lanes differ (default: middle lane)")
    ap.add_argument("--aspect", type=float, default=1.0,
                    help="width/height aspect the engine frame expects for head+receptor (default 1.0 = square)")
    ap.add_argument("--name", default=None, help="display name (default: skin.ini Name)")
    args = ap.parse_args()
    ini_path = os.path.join(args.skin_dir, "skin.ini")
    if not os.path.isfile(ini_path):
        print(f"error: {ini_path} not found", file=sys.stderr)
        sys.exit(1)
    convert_osu_skin(args.skin_dir, args.out, keys=args.keys, lane=args.lane,
                     aspect=args.aspect, name=args.name)


if __name__ == "__main__":
    main()
