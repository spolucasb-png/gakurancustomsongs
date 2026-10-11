#!/usr/bin/env python3
"""Etterna noteskin -> GakuranChart skin pack converter.

Reads an Etterna/SM5 noteskin folder (Noteskin.lua + metrics.ini) and produces
a GakuranCharts/Skins/<slug>/ pack in the same schema as tools/osu2skin.py.

This targets single-arrow noteskins like AmbieArrowsFFR, where every
direction redirects to one set of sprites (ButtonRedir all -> Up, no
rotation), so all 4 lanes share one head/receptor pair:
  * tap: Notes/_Up Tap Note (+ ButtonRedir fallback to any direction present)
  * receptor: Receptors/_Up Go Receptor; pressed: _Up Press Receptor
  * hold body: Holds/Up Hold Body Active; bottom cap -> symmetric tail caps
    (same rule as the osu! converter: caps at both ends)

Pure stdlib: PNG work is imported from osu2skin, not copied.

Usage:
    python tools/etterna2skin.py "path/to/noteskin" --out <Skins dir>
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import osu2skin as o2s


def pjoin(*parts):
    return os.path.join(*parts)


def find_sprite(skin_dir, folder, stems):
    """First PNG under folder whose name starts with any stem (case-insensitive).

    Etterna sprites carry resolution suffixes
    ("_Up Tap Note 1x1 (res 64x64).png"), so prefix match, not exact match.
    """
    base = pjoin(skin_dir, folder)
    if not os.path.isdir(base):
        return None
    files = sorted(os.listdir(base))
    for stem in stems:
        s = stem.lower()
        for e in files:
            el = e.lower()
            if el.endswith(".png") and el.startswith(s):
                return pjoin(base, e)
    return None


def convert_etterna_skin(skin_dir, out, aspect=1.0, name=None):
    """Convert an Etterna noteskin folder into a GakuranChart pack; return out_dir."""
    if not os.path.isfile(pjoin(skin_dir, "Noteskin.lua")):
        raise FileNotFoundError(pjoin(skin_dir, "Noteskin.lua"))

    dirs = ["_Up", "_Down", "_Left", "_Right", "Up", "Down", "Left", "Right"]
    head_path = find_sprite(skin_dir, "Notes", [f"{d} Tap Note" for d in dirs])
    receptor_path = find_sprite(skin_dir, "Receptors", [f"{d} Go Receptor" for d in dirs])
    receptor_down_path = find_sprite(skin_dir, "Receptors",
                                     [f"{d} Press Receptor" for d in dirs])
    body_path = find_sprite(skin_dir, "Holds",
                            [f"{d} Hold Body Active" for d in dirs] + ["Hold Body Active"])
    cap_path = find_sprite(skin_dir, "Holds",
                           [f"{d} Hold BottomCap Active" for d in dirs]
                           + [f"{d} Hold Bottomcap Active" for d in dirs])
    if not head_path:
        print("error: no tap note sprite (Notes/* Tap Note)", file=sys.stderr)
        sys.exit(1)
    if not receptor_path:
        print("warning: no receptor sprite, reusing tap image", file=sys.stderr)
        receptor_path = head_path
    if not body_path:
        print("warning: no hold body sprite; holds will use the tap image as a plain bar",
              file=sys.stderr)
        body_path = head_path

    hw, hh, head_px = o2s.png_decode(open(head_path, "rb").read())
    head_src = (hw, hh, o2s.alpha_bbox(head_px, hw, hh))
    hw, hh, head_px = o2s.fit_to_frame(head_px, hw, hh, aspect, head_src[2])
    # Per-lane arrows: dance layout Left/Down/Up/Right on lanes 1-4. The base
    # head is the Up arrow (lane 3 reuses it); other lanes get tapN sprites
    # through manifest.taps. (The noteskin's own redirect is all-Up; players
    # expect directions, so the real art is used instead.)
    lane_dirs = {1: "Left", 2: "Down", 4: "Right"}
    rw, rh, rec_px = o2s.png_decode(open(receptor_path, "rb").read())
    rec_src = (rw, rh, o2s.alpha_bbox(rec_px, rw, rh))
    rw, rh, rec_px = o2s.fit_to_frame(rec_px, rw, rh, aspect, rec_src[2])

    def same(a, b):
        return os.path.normcase(os.path.abspath(a)) == os.path.normcase(os.path.abspath(b))

    def optional(path, label, base_src):
        if not path:
            return None
        try:
            ow, oh, opx = o2s.png_decode(open(path, "rb").read())
        except Exception as e:
            print(f"warning: could not read {label}: {e}; skipping", file=sys.stderr)
            return None
        box = o2s.alpha_bbox(opx, ow, oh)
        if box is None:
            return None
        if (ow, oh) == (base_src[0], base_src[1]):
            ref = o2s.shared_box(box, base_src[2])
            if ref is not None:
                box = ref
        ow, oh, opx = o2s.fit_to_frame(opx, ow, oh, aspect, box)
        return o2s.png_encode(ow, oh, opx)

    receptor_down_out = optional(receptor_down_path, "pressed receptor", rec_src) \
        if receptor_down_path and not same(receptor_down_path, receptor_path) else None

    # Per-lane receptors (dance layout, like the taps). The base receptor is
    # the Up pair; other directions become recN/recPN through
    # manifest.receptors. Lanes reusing the base files are skipped (fallback).
    lane_dirs_full = {1: "Left", 2: "Down", 3: "Up", 4: "Right"}
    rec_map, recp_map = {}, {}
    for j, direction in lane_dirs_full.items():
        g = find_sprite(skin_dir, "Receptors", [f"_{direction} Go Receptor"])
        if g and not same(g, receptor_path):
            res = optional(g, f"lane {j} receptor", rec_src)
            if res:
                rec_map[j] = res
        q = find_sprite(skin_dir, "Receptors", [f"_{direction} Press Receptor"])
        if q and not same(q, receptor_down_path or receptor_path):
            res = optional(q, f"lane {j} pressed receptor", rec_src)
            if res:
                recp_map[j] = res

    bw, bh, body_px = o2s.png_decode(open(body_path, "rb").read())
    # "doubleres" art is ~2x the note width (104px body vs ~58px arrows):
    # normalize holds to the framed head width, otherwise holds render fat.
    if bw != hw:
        nh = max(1, round(bh * hw / bw))
        body_px = o2s.resize_nearest(body_px, bw, bh, hw, nh)
        bw, bh = hw, nh
    canvas_h, cap_h, cap_px = bh, 0, None
    slice_y1, slice_y2 = 0, max(1, bh)
    if cap_path:
        cap_w, cap_h, cap_px = o2s.png_decode(open(cap_path, "rb").read())
        box = o2s.alpha_bbox(cap_px, cap_w, cap_h)
        if box is not None:
            cap_w, cap_h, cap_px = crop_to_box(cap_px, cap_w, cap_h, box)
        if cap_w != bw:
            cap_px = o2s.resize_nearest(cap_px, cap_w, cap_h, bw,
                                        max(1, round(cap_h * bw / cap_w)))
            cap_h = max(1, round(cap_h * bw / cap_w))
        slice_y1, slice_y2 = cap_h, cap_h + bh
        canvas_h = cap_h + bh + cap_h
    row = bw * 4
    canvas = bytearray(bw * canvas_h * 4)
    if cap_px:
        # chevron points outward at both ends (as-is on top, flipped copy at
        # the bottom): the osu! convention points both tips inward here.
        canvas[0:cap_h * row] = cap_px
        canvas[cap_h * row:(cap_h + bh) * row] = body_px
        canvas[(cap_h + bh) * row:(cap_h * 2 + bh) * row] = \
            o2s.flip_vertical(cap_px, bw, cap_h)
    else:
        canvas[0:bh * row] = body_px

    lane_taps = {}
    for j, direction in lane_dirs.items():
        p = find_sprite(skin_dir, "Notes", [f"_{direction} Tap Note"])
        if p and not same(p, head_path):
            try:
                ow, oh, opx = o2s.png_decode(open(p, "rb").read())
            except Exception as e:
                print(f"warning: could not read lane {j} tap: {e}; skipping",
                      file=sys.stderr)
                continue
            box = o2s.alpha_bbox(opx, ow, oh)
            if box is None:
                continue
            if (ow, oh) == (head_src[0], head_src[1]):
                ref = o2s.shared_box(box, head_src[2])
                if ref is not None:
                    box = ref
            ow, oh, opx = o2s.fit_to_frame(opx, ow, oh, aspect, box)
            lane_taps[j] = o2s.png_encode(ow, oh, opx)

    name = name or os.path.basename(os.path.normpath(skin_dir))
    slug = re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").lower() or "skin"
    shape_key = "GK_" + re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_")
    out_dir = os.path.join(out, slug)
    os.makedirs(out_dir, exist_ok=True)
    with open(pjoin(out_dir, "head.png"), "wb") as f:
        f.write(o2s.png_encode(hw, hh, head_px))
    with open(pjoin(out_dir, "receptor.png"), "wb") as f:
        f.write(o2s.png_encode(rw, rh, rec_px))
    with open(pjoin(out_dir, "tail.png"), "wb") as f:
        f.write(o2s.png_encode(bw, canvas_h, canvas))
    wanted = {"head.png", "receptor.png", "tail.png", "manifest.json"}
    if receptor_down_out is not None:
        wanted.add("receptorPressed.png")
        with open(pjoin(out_dir, "receptorPressed.png"), "wb") as f:
            f.write(receptor_down_out)
    elif os.path.isfile(pjoin(out_dir, "receptorPressed.png")):
        os.remove(pjoin(out_dir, "receptorPressed.png"))
    for j, png in sorted(lane_taps.items()):
        fname = f"tap{j}.png"
        wanted.add(fname)
        with open(pjoin(out_dir, fname), "wb") as f:
            f.write(png)
    for j, png in sorted(rec_map.items()):
        fname = f"rec{j}.png"
        wanted.add(fname)
        with open(pjoin(out_dir, fname), "wb") as f:
            f.write(png)
    for j, png in sorted(recp_map.items()):
        fname = f"recP{j}.png"
        wanted.add(fname)
        with open(pjoin(out_dir, fname), "wb") as f:
            f.write(png)
    for entry in os.listdir(out_dir):
        if entry.endswith(".png") and entry not in wanted and (
                entry.startswith("tap") or entry.startswith("rec")):
            os.remove(pjoin(out_dir, entry))

    manifest = {
        "name": name, "shapeKey": shape_key,
        "head": "head.png", "receptor": "receptor.png", "tail": "tail.png",
        "tailW": bw, "tailH": canvas_h,
        "slice": [bw // 2 - 1, slice_y1, bw // 2 + 1, slice_y2],
        "source": {"skinDir": skin_dir, "keys": 4, "format": "etterna"},
    }
    if receptor_down_out is not None:
        manifest["receptorPressed"] = "receptorPressed.png"
    if lane_taps:
        manifest["taps"] = {str(j): f"tap{j}.png" for j in sorted(lane_taps)}
    if rec_map:
        manifest["receptors"] = {str(j): f"rec{j}.png" for j in sorted(rec_map)}
    if recp_map:
        manifest["receptorsPressed"] = {str(j): f"recP{j}.png" for j in sorted(recp_map)}
    with open(pjoin(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    print(f"pack: {out_dir}  taps={sorted(lane_taps) or '-'} "
          f"recs={sorted(rec_map) or '-'} "
          f"pressed={'y' if receptor_down_out else 'n'}")
    return out_dir


def crop_to_box(rgba: bytes, w: int, h: int, box):
    """Crop RGBA art to its alpha bounding box (kills transparent dead space).

    The etterna bottom-cap art sits in a small corner of a 128px canvas; used
    raw, the transparent remainder renders as a visible gap between the hold
    body and the tip. Cropping first removes the gap.
    """
    minx, miny, maxx, maxy = box
    cw, ch = maxx - minx, maxy - miny
    out = bytearray(cw * ch * 4)
    for y in range(ch):
        src = ((miny + y) * w + minx) * 4
        out[y * cw * 4:(y + 1) * cw * 4] = rgba[src:src + cw * 4]
    return cw, ch, bytes(out)


def main():
    ap = argparse.ArgumentParser(description="Convert an Etterna noteskin into a GakuranChart skin pack")
    ap.add_argument("skin_dir", help="Etterna noteskin folder (contains Noteskin.lua)")
    ap.add_argument("--out", required=True, help="output Skins directory")
    ap.add_argument("--aspect", type=float, default=1.0)
    ap.add_argument("--name", default=None)
    args = ap.parse_args()
    try:
        convert_etterna_skin(args.skin_dir, args.out,
                             aspect=args.aspect, name=args.name)
    except FileNotFoundError as e:
        print(f"error: {e} not found", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
