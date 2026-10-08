#!/usr/bin/env python3
"""Calibrate a synth_scene.py scene with bev-calib and measure the result
against the true cameras.

For every ground point within --radius of each camera, the point goes through
the true pose and lens, and separately through the solved hb2i and the lens
file in the scene directory (as the renderer does). The distance between the
two, in image pixels, is the error a viewer would see in the stitched view.
Replace a lens file in the scene directory with one from lens calibration to
measure the whole chain.

Usage:
    python3 check_synth.py <layout.ini> <scene dir> [--bev-calib build/bev-calib]
"""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

from synth_scene import project, read_layout

REPO = Path(__file__).resolve().parent.parent


def find_bev_calib(given):
    if given:
        return given
    for p in sorted(REPO.glob("build*/bev-calib")):
        return str(p)
    return shutil.which("bev-calib")


def read_lens(path):
    vals = dict(l.split(" = ") for l in Path(path).read_text().splitlines() if " = " in l)
    K = np.array([[float(vals["fx"]), 0, float(vals["cx"])], [0, float(vals["fy"]), float(vals["cy"])], [0, 0, 1]])
    fisheye = vals.get("model", "pinhole") == "fisheye"
    keys = ("k1", "k2", "k3", "k4") if fisheye else ("k1", "k2", "p1", "p2", "k3")
    return K, [float(vals.get(k, 0)) for k in keys], fisheye


def distort(u, K, D, fisheye):
    """Undistorted pixels to raw pixels, as the renderer's shader does."""
    x = (u - K[:2, 2]) / np.diag(K)[:2]
    if fisheye:
        r = np.linalg.norm(x, axis=1)
        th = np.arctan(r)
        t2 = th * th
        thd = th * (1 + t2 * (D[0] + t2 * (D[1] + t2 * (D[2] + t2 * D[3]))))
        x = x * np.where(r > 1e-9, thd / np.maximum(r, 1e-12), 1)[:, None]
    else:
        r2 = (x ** 2).sum(1)
        rad = 1 + D[0] * r2 + D[1] * r2 ** 2 + D[4] * r2 ** 3
        xx, yy = x[:, 0], x[:, 1]
        x = np.stack([xx * rad + 2 * D[2] * xx * yy + D[3] * (r2 + 2 * xx * xx),
                      yy * rad + D[2] * (r2 + 2 * yy * yy) + 2 * D[3] * xx * yy], 1)
    return x * np.diag(K)[:2] + K[:2, 2]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("layout", type=Path)
    ap.add_argument("scene", type=Path)
    ap.add_argument("--bev-calib", help="path to the bev-calib binary (default: build*/bev-calib)")
    ap.add_argument("--radius", type=float, default=4.0, help="metres around each camera to score")
    args = ap.parse_args()

    tool = find_bev_calib(args.bev_calib)
    if not tool:
        sys.exit("bev-calib not found; build it with -DENABLE_CALIB=ON or pass --bev-calib")
    truth = json.load(open(args.scene / "truth.json"))
    K, D, fisheye = np.array(truth["K"]), np.array(truth["D"]), truth["fisheye"]
    W, H = truth["size"]
    layout = read_layout(args.layout)

    images = [str(args.scene / f"{c['position']}.png") for c in layout["cameras"]]
    run = subprocess.run([tool, str(args.layout), *images, "--lens-dir", str(args.scene)],
                         capture_output=True, text=True)
    print(run.stdout + run.stderr, end="")
    hb2i = [np.array([float(v) for v in l.split("=")[1].split()]).reshape(3, 3).T
            for l in run.stdout.splitlines() if "hb2i =" in l]
    if len(hb2i) != len(layout["cameras"]):
        sys.exit("not every camera solved, nothing to score")

    print(f"\nerror against the true cameras, ground within {args.radius:g} m of each:")
    grid = np.stack(np.meshgrid(np.arange(-6, 6.01, 0.1), np.arange(-7, 7.01, 0.1)), -1).reshape(-1, 2)
    for cam, H_cam in zip(layout["cameras"], hb2i):
        pose = truth["cams"][cam["position"]]
        C, R = np.array(pose["C"]), np.array(pose["R"])
        g = grid[np.linalg.norm(grid - C[:2], axis=1) < args.radius]
        true_px, depth = project(K, D, fisheye, C, R, g)
        to_point = np.c_[g, np.zeros(len(g))] - C
        angle = np.degrees(np.arccos(np.clip((to_point @ R)[:, 2] / np.linalg.norm(to_point, axis=1), -1, 1)))
        seen = ((depth > 0) & (angle < 80) & (true_px[:, 0] >= 0) & (true_px[:, 1] >= 0)
                & (true_px[:, 0] < W) & (true_px[:, 1] < H))
        lens_file = args.scene / f"{cam['lens']}-lens.ini"
        if cam["lens"] and lens_file.exists():
            KL, DL, fl = read_lens(lens_file)
        else:
            KL, DL, fl = np.eye(3), None, None
        h = (H_cam @ np.c_[g[seen], np.ones(seen.sum())].T).T
        und = h[:, :2] / h[:, 2:]
        est = und if DL is None else distort(und, KL, DL, fl)
        e = np.linalg.norm(est - true_px[seen], axis=1)
        print(f"  {cam['position']:12s} {seen.sum():5d} points  median {np.median(e):.2f} px  "
              f"p95 {np.percentile(e, 95):.2f} px  max {e.max():.2f} px")


if __name__ == "__main__":
    main()
