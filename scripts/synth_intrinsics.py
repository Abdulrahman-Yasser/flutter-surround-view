#!/usr/bin/env python3
"""Photos of one ChArUco board at random poses through a known lens, to test
lens calibration (bev-calib --intrinsics) against the truth.

Poses aim the board all over the frame, edges included, as a fisheye fit
needs. Writes the photos, a board.ini to calibrate with, and truth-lens.ini.

Usage:
    python3 synth_intrinsics.py --out intr --lens fisheye
    bev-calib --intrinsics intr/board.ini intr/view*.png --fisheye --lens-out fitted-lens.ini
    diff intr/truth-lens.ini fitted-lens.ini
"""
import argparse
import math
from pathlib import Path

import cv2
import numpy as np

from synth_scene import LENSES, pixel_rays, write_lens_ini


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=Path("intr"))
    ap.add_argument("--lens", choices=sorted(LENSES), default="fisheye")
    ap.add_argument("--views", type=int, default=18)
    ap.add_argument("--squares", default="7x5", help="columns x rows")
    ap.add_argument("--square", type=float, default=0.04, help="metres")
    ap.add_argument("--marker", type=float, default=0.03, help="metres")
    ap.add_argument("--dict", default="4X4_50")
    ap.add_argument("--size", default="3280x2464")
    ap.add_argument("--seed", type=int, default=3)
    args = ap.parse_args()

    size = tuple(int(v) for v in args.size.lower().split("x"))
    K = np.array(LENSES[args.lens]["K"], dtype=np.float64)
    K[:2] *= size[0] / 3280.0
    D = np.array(LENSES[args.lens]["D"])
    sx, sy = (int(v) for v in args.squares.lower().split("x"))

    d = cv2.aruco.getPredefinedDictionary(getattr(cv2.aruco, "DICT_" + args.dict))
    board = cv2.aruco.CharucoBoard((sx, sy), args.square, args.marker, d)
    board.setLegacyPattern(True)
    ppm, pad = 8000.0, 200
    sheet = board.generateImage((round(sx * args.square * ppm), round(sy * args.square * ppm)), marginSize=0)
    sheet = cv2.copyMakeBorder(sheet, pad, pad, pad, pad, cv2.BORDER_CONSTANT, value=255)

    args.out.mkdir(parents=True, exist_ok=True)
    rays = pixel_rays(K, D, args.lens == "fisheye", size)
    rng = np.random.default_rng(args.seed)
    centre = np.array([sx * args.square / 2, sy * args.square / 2, 0])
    for i in range(args.views):
        R, _ = cv2.Rodrigues(rng.uniform(-0.6, 0.6, 3))
        a, off_axis = rng.uniform(0, 2 * math.pi), rng.uniform(0, 1.2 if args.lens == "fisheye" else 0.4)
        aim = np.array([math.sin(off_axis) * math.cos(a), math.sin(off_axis) * math.sin(a), math.cos(off_axis)])
        T = aim * rng.uniform(0.35, 0.6) - R @ centre
        normal = R[:, 2]
        with np.errstate(divide="ignore", invalid="ignore"):
            t = (normal @ T) / (rays @ normal)
        on_board = (rays * t[..., None] - T) @ R
        u = (on_board[..., 0] * ppm + pad).astype(np.float32)
        v = (on_board[..., 1] * ppm + pad).astype(np.float32)
        behind = ~(t > 0) | (rays[..., 2] < 0.02)
        u[behind] = -1
        v[behind] = -1
        view = cv2.remap(sheet, u, v, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=150)
        cv2.imwrite(str(args.out / f"view{i:02d}.png"), view)

    (args.out / "board.ini").write_text(
        f"[camera]\nposition = front\n[board]\ndict = {args.dict}\nsquares = {args.squares}\n"
        f"square = {args.square}\nmarker = {args.marker}\n")
    write_lens_ini(args.out / "truth-lens.ini", args.lens, K, D, size)
    print(f"wrote {args.views} views, board.ini and truth-lens.ini to {args.out}")


if __name__ == "__main__":
    main()
