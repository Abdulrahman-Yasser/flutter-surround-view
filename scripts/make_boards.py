#!/usr/bin/env python3
"""Render every ChArUco board a calibration layout needs as a print-ready PDF.

Each board gets its own marker id range (first_id in the layout), so the
boards are not interchangeable: print each file once and lay it where the
layout's diagram puts it. Print at 100% / "actual size"; a 6x8 board of
90 mm squares is 540 x 720 mm, a poster print.

Usage:
    python3 make_boards.py ../flutter/bev_calib/layouts/four_cam.ini [--out boards/] [--dpi 300]
"""
import argparse
import configparser
import itertools
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw

MARGIN_MM = 15


def read_boards(path):
    # Repeated [board] sections are not valid configparser input; number them.
    counter = itertools.count()
    text = "".join(
        f"[board{next(counter)}]\n" if line.strip() == "[board]" else line
        for line in Path(path).read_text().splitlines(keepends=True)
    )
    cp = configparser.ConfigParser(strict=False, inline_comment_prefixes="#")
    cp.read_string("[global]\n" + text)
    boards = []
    for name in cp.sections():
        if not name.startswith("board"):
            continue
        s = cp[name]
        sx, sy = (int(v) for v in s.get("squares", "6x8").lower().split("x"))
        boards.append(dict(
            dict=s.get("dict", "4X4_50"),
            squares_x=sx,
            squares_y=sy,
            square=float(s.get("square", "0.090")),
            marker=float(s.get("marker", "0.070")),
            first_id=int(s.get("first_id", "0")),
            legacy=s.get("legacy", "1") != "0",
        ))
    return boards


def render(b, dpi):
    px_per_m = dpi / 0.0254
    d = cv2.aruco.getPredefinedDictionary(getattr(cv2.aruco, "DICT_" + b["dict"]))
    n = b["squares_x"] * b["squares_y"] // 2
    board = cv2.aruco.CharucoBoard((b["squares_x"], b["squares_y"]), b["square"], b["marker"], d,
                                   np.arange(b["first_id"], b["first_id"] + n))
    board.setLegacyPattern(b["legacy"])
    w = round(b["squares_x"] * b["square"] * px_per_m)
    h = round(b["squares_y"] * b["square"] * px_per_m)
    margin = round(MARGIN_MM / 1000 * px_per_m)
    img = board.generateImage((w, h), marginSize=0)
    page = Image.new("L", (w + 2 * margin, h + 2 * margin), 255)
    page.paste(Image.fromarray(img), (margin, margin))
    label = (f"{b['dict']}  ids {b['first_id']}-{b['first_id'] + n - 1}  "
             f"{b['squares_x']}x{b['squares_y']}  {b['square'] * 1000:g}/{b['marker'] * 1000:g} mm  "
             f"TOP EDGE")
    ImageDraw.Draw(page).text((margin, margin // 3), label, fill=0)
    return page


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("layout", type=Path)
    ap.add_argument("--out", type=Path, default=Path("boards"))
    ap.add_argument("--dpi", type=int, default=300)
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    for b in read_boards(args.layout):
        page = render(b, args.dpi)
        path = args.out / f"charuco_{b['dict']}_id{b['first_id']}_{b['squares_x']}x{b['squares_y']}.pdf"
        page.save(path, resolution=args.dpi)
        mm = (page.width / args.dpi * 25.4, page.height / args.dpi * 25.4)
        print(f"wrote {path}  ({mm[0]:.0f} x {mm[1]:.0f} mm)")


if __name__ == "__main__":
    main()
