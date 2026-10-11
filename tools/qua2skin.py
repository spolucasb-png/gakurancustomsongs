#!/usr/bin/env python3
"""Quaver skin (4K) -> GakuranChart skin pack converter.

Reads a Quaver skin folder (skin.ini + conventional 4k/ paths) and produces
a GakuranCharts/Skins/<slug>/ pack in the same schema as tools/osu2skin.py
(head/receptor/tail + optional per-lane taps, pressed receptor, hold head).

Mapping (4K):
  * tap base lane 2 (middle): 4k/HitObjects/note-hitobject-2; lanes whose art
    differs (outer grey vs inner purple) become tap1/3/4 via manifest.taps
  * receptor: 4k/Receptors/receptor-up-2; pressed: receptor-down-2
  * hold: body note-holdbody-2 + end note-holdend-2 (composited tail, same
    symmetric-cap rule as the osu! converter); head: note-holdhitobject-2

Pure stdlib: PNG work is imported from osu2skin, not copied.

Usage:
    python tools/qua2skin.py "path/to/quaver skin" --out <Skins dir> [--lane 2]
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


def convert_quaver_skin(skin_dir, out, lane=2, aspect=1.0, name=None):
    """Convert a Quaver 4K skin folder into a GakuranChart pack; return out_dir."""
    if not os.path.isfile(pjoin(skin_dir, "skin.ini")):
        raise FileNotFoundError(pjoin(skin_dir, "skin.ini"))
    keys = 4

    def art(*parts):
        return o2s.resolve_ref(skin_dir, "/".join(parts))

    head_path = art("4k", "HitObjects", f"note-hitobject-{lane}")
    receptor_path = art("4k", "Receptors", f"receptor-up-{lane}")
    body_path = art("4k", "HitObjects", f"note-holdbody-{lane}")
    cap_path = art("4k", "HitObjects", f"note-holdend-{lane}")
    head_hold_path = art("4k", "HitObjects", f"note-holdhitobject-{lane}")
    receptor_down_path = art("4k", "Receptors", f"receptor-down-{lane}")
    if not head_path:
        print("error: no tap art (4k/HitObjects/note-hitobject-N)", file=sys.stderr)
        sys.exit(1)
    if not receptor_path:
        print("warning: no receptor art, reusing tap image", file=sys.stderr)
        receptor_path = head_path
    if not body_path:
        print("warning: no hold body art; holds will use the tap image as a plain bar",
              file=sys.stderr)
        body_path = head_path

    hw, hh, head_px = o2s.png_decode(open(head_path, "rb").read())
    head_src = (hw, hh, o2s.alpha_bbox(head_px, hw, hh))
    hw, hh, head_px = o2s.fit_to_frame(head_px, hw, hh, aspect, head_src[2])
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

    hold_head_out = optional(head_hold_path, "hold head", head_src) \
        if head_hold_path and not same(head_hold_path, head_path) else None
    receptor_down_out = optional(receptor_down_path, "pressed receptor", rec_src) \
        if receptor_down_path and not same(receptor_down_path, receptor_path) else None

    lane_taps = {}
    for j in range(1, keys + 1):
        if j == lane:
            continue
        p = art("4k", "HitObjects", f"note-hitobject-{j}")
        if p and not same(p, head_path):
            res = optional(p, f"lane {j} tap", head_src)
            if res:
                lane_taps[j] = res

    bw, bh, body_px = o2s.png_decode(open(body_path, "rb").read())
    canvas_h, cap_h, cap_px = bh, 0, None
    slice_y1, slice_y2 = 0, max(1, bh)
    if cap_path:
        cap_w, cap_h, cap_px = o2s.png_decode(open(cap_path, "rb").read())
        if cap_w != bw:
            cap_px = o2s.resize_nearest(cap_px, cap_w, cap_h, bw, cap_h)
        slice_y1, slice_y2 = cap_h, cap_h + bh
        canvas_h = cap_h + bh + cap_h
    row = bw * 4
    canvas = bytearray(bw * canvas_h * 4)
    if cap_px:
        # Quaver end art points the WRONG way for the osu! convention (its
        # dome faces the body when flipped on top): as-is on top, flipped
        # copy at the bottom, so both tips face outward. Verified by eyeball.
        canvas[0:cap_h * row] = cap_px
        canvas[cap_h * row:(cap_h + bh) * row] = body_px
        canvas[(cap_h + bh) * row:(cap_h * 2 + bh) * row] = \
            o2s.flip_vertical(cap_px, bw, cap_h)
    else:
        canvas[0:bh * row] = body_px

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
    for fname, data in (("headHold.png", hold_head_out),
                        ("receptorPressed.png", receptor_down_out),
                        *((f"tap{l}.png", lane_taps[l]) for l in sorted(lane_taps))):
        wanted.add(fname)
        target = pjoin(out_dir, fname)
        if data is not None:
            with open(target, "wb") as f:
                f.write(data)
        elif os.path.isfile(target):
            os.remove(target)

    manifest = {
        "name": name, "shapeKey": shape_key,
        "head": "head.png", "receptor": "receptor.png", "tail": "tail.png",
        "tailW": bw, "tailH": canvas_h,
        "slice": [bw // 2 - 1, slice_y1, bw // 2 + 1, slice_y2],
        "source": {"skinDir": skin_dir, "keys": keys, "lane": lane, "format": "quaver"},
    }
    if hold_head_out is not None:
        manifest["headHold"] = "headHold.png"
    if receptor_down_out is not None:
        manifest["receptorPressed"] = "receptorPressed.png"
    if lane_taps:
        manifest["taps"] = {str(l): f"tap{l}.png" for l in sorted(lane_taps)}
    with open(pjoin(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    print(f"pack: {out_dir}  taps={sorted(lane_taps) or '-'} "
          f"holdhead={'y' if hold_head_out else 'n'} pressed={'y' if receptor_down_out else 'n'}")
    return out_dir


def main():
    ap = argparse.ArgumentParser(description="Convert a Quaver 4K skin into a GakuranChart skin pack")
    ap.add_argument("skin_dir", help="Quaver skin folder (contains skin.ini)")
    ap.add_argument("--out", required=True, help="output Skins directory")
    ap.add_argument("--lane", type=int, default=2, help="1-based base lane (default 2)")
    ap.add_argument("--aspect", type=float, default=1.0)
    ap.add_argument("--name", default=None)
    args = ap.parse_args()
    try:
        convert_quaver_skin(args.skin_dir, args.out, lane=args.lane,
                            aspect=args.aspect, name=args.name)
    except FileNotFoundError as e:
        print(f"error: {e} not found", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
