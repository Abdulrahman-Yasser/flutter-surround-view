#!/usr/bin/env python3
"""Render what the cameras of a calibration layout would see, with a known lens
and known poses, to test the calibration without a car.

The boards are drawn onto a top-down picture of the floor where the layout
puts them, and every camera image is rendered backwards: each pixel's ray goes
out through the lens model, hits the ground plane, and takes the floor colour
there. Cameras sit on the car outline at their layout position, facing their
layout direction, tilted down.

Writes into --out:
    <position>.png        one image per layout camera (front_left.png ...),
                          the names BEV_CALIB_IMAGES expects
    <lens>-lens.ini       the exact lens, under every lens name the layout uses
    truth.json            lens, image size and each camera's pose, for
                          check_synth.py

Usage:
    python3 synth_scene.py ../flutter/bev_calib/layouts/four_cam_squares.ini --out synth
    python3 synth_scene.py front_pair.ini --out synth_pin --lens pinhole --pitch 30
"""
import argparse
import configparser
import itertools
import json
import math
from pathlib import Path

import cv2
import numpy as np

GROUND_PPM = 500.0
X0, X1, Y0, Y1 = -6.0, 6.0, -7.0, 7.0

# name: (default facing deg, mount x in half-widths, mount y in half-lengths);
# matches CameraPosition in flutter/bev_calib and BevPosition in bev_config.h.
POSITIONS = {
    "front_left": (135, -0.6, 1), "front_right": (45, 0.6, 1),
    "back_left": (225, -0.6, -1), "back_right": (315, 0.6, -1),
    "front": (90, 0, 1), "right": (0, 1, 0), "back": (270, 0, -1), "left": (180, -1, 0),
}
SLOT_POSITIONS = ["front_left", "front_right", "back_left", "back_right"]
FACING_WORDS = {"front": 90, "right": 0, "back": 270, "left": 180}

# An IMX219 still with a ~190 degree fisheye, and the same sensor with a
# narrow pinhole lens.
LENSES = {
    "fisheye": dict(K=[[935.0, 0, 1652], [0, 933.0, 1220], [0, 0, 1]],
                    D=[0.02, -0.006, 0.001, -0.0002]),
    "pinhole": dict(K=[[1790.0, 0, 1645], [0, 1790.0, 1225], [0, 0, 1]],
                    D=[-0.30, 0.10, 0.0005, -0.0003, -0.015]),
}


def read_layout(path):
    # Repeated [camera]/[board] sections aren't valid configparser input; number them.
    counter = itertools.count()
    text = "".join(
        f"[{line.strip()[1:-1]}{next(counter)}]\n" if line.strip() in ("[board]", "[camera]") else line
        for line in Path(path).read_text().splitlines(keepends=True))
    cp = configparser.ConfigParser(strict=False, inline_comment_prefixes="#")
    cp.read_string("[global]\n" + text)
    g = cp["global"]
    layout = dict(car_width=float(g.get("car_width", "1.8")), car_length=float(g.get("car_length", "4.5")),
                  cameras=[], boards=[])
    for name in cp.sections():
        s = cp[name]
        if name.startswith("camera"):
            pos = s.get("position") or SLOT_POSITIONS[int(s["slot"])]
            facing = s.get("facing")
            if facing is None:
                deg = POSITIONS[pos][0]
            elif facing in POSITIONS:
                deg = POSITIONS[facing][0]
            else:
                deg = FACING_WORDS.get(facing, None)
                deg = float(facing) if deg is None else deg
            layout["cameras"].append(dict(position=pos, facing=deg, lens=s.get("lens", "")))
        elif name.startswith("board"):
            square = s.get("type", "charuco") == "square"
            sx, sy = (1, 1) if square else (int(v) for v in s.get("squares", "6x8").lower().split("x"))
            layout["boards"].append(dict(
                square=square, dict=s.get("dict", "4X4_50"), sx=sx, sy=sy,
                side=float(s.get("size" if square else "square", "0.09")),
                marker=float(s.get("marker", "0.07")), first_id=int(s.get("first_id", "0")),
                legacy=s.get("legacy", "1") != "0",
                x=float(s.get("x", "0")), y=float(s.get("y", "0")), yaw=float(s.get("yaw", "0"))))
    return layout


def sheet_to_world(b, p):
    w, h = b["sx"] * b["side"], b["sy"] * b["side"]
    c, s = math.cos(math.radians(b["yaw"])), math.sin(math.radians(b["yaw"]))
    u, v = p[0] - w / 2, h / 2 - p[1]
    return b["x"] + u * c - v * s, b["y"] + u * s + v * c


def world_to_ground(x, y):
    return (x - X0) * GROUND_PPM, (Y1 - y) * GROUND_PPM


def damage(g, boards, rng):
    """Spoils parts of the boards as real ones get spoiled, so the detector
    misses corners: a dark smudge over two markers of every ChArUco board,
    glare over one corner of every black square."""
    for b in boards:
        w, h = b["sx"] * b["side"], b["sy"] * b["side"]
        if b["square"]:
            centre = world_to_ground(*sheet_to_world(b, (0, 0)))
            r = int(0.18 * b["side"] * GROUND_PPM)
            cv2.circle(g, np.int32(centre), r, 245, cv2.FILLED, cv2.LINE_AA)
            continue
        d = cv2.aruco.getPredefinedDictionary(getattr(cv2.aruco, "DICT_" + b["dict"]))
        n = b["sx"] * b["sy"] // 2
        board = cv2.aruco.CharucoBoard((b["sx"], b["sy"]), b["side"], b["marker"], d,
                                       np.arange(b["first_id"], b["first_id"] + n))
        board.setLegacyPattern(b["legacy"])
        markers = board.getObjPoints()
        for k in rng.choice(len(markers), size=min(2, len(markers)), replace=False):
            c = np.asarray(markers[k])[:, :2].mean(axis=0)
            centre = world_to_ground(*sheet_to_world(b, (c[0], c[1])))
            axes = (int(0.55 * b["side"] * GROUND_PPM), int(0.4 * b["side"] * GROUND_PPM))
            cv2.ellipse(g, np.int32(centre), axes, float(rng.uniform(0, 180)), 0, 360, 70, cv2.FILLED, cv2.LINE_AA)


def ground_image(boards, seed=1, damaged=False):
    rng = np.random.default_rng(seed)
    W, H = int((X1 - X0) * GROUND_PPM), int((Y1 - Y0) * GROUND_PPM)
    noise = cv2.GaussianBlur(rng.normal(0, 12, (H // 8, W // 8)).astype(np.float32), (0, 0), 2)
    g = np.clip(175 + cv2.resize(noise, (W, H)), 0, 255).astype(np.uint8)
    for b in boards:
        w, h = b["sx"] * b["side"], b["sy"] * b["side"]
        m = 0.12 if b["square"] else 0.03
        paper = [sheet_to_world(b, p) for p in [(-m, -m), (w + m, -m), (w + m, h + m), (-m, h + m)]]
        cv2.fillPoly(g, [np.int32([world_to_ground(*p) for p in paper])], 245)
        if b["square"]:
            pts = [world_to_ground(*sheet_to_world(b, p)) for p in [(0, 0), (w, 0), (w, h), (0, h)]]
            cv2.fillPoly(g, [np.int32(np.round(np.array(pts) * 16))], 20, lineType=cv2.LINE_AA, shift=4)
            continue
        d = cv2.aruco.getPredefinedDictionary(getattr(cv2.aruco, "DICT_" + b["dict"]))
        n = b["sx"] * b["sy"] // 2
        board = cv2.aruco.CharucoBoard((b["sx"], b["sy"]), b["side"], b["marker"], d,
                                       np.arange(b["first_id"], b["first_id"] + n))
        board.setLegacyPattern(b["legacy"])
        bp = 2000.0
        img = board.generateImage((round(w * bp), round(h * bp)), marginSize=0)
        img = np.where(img > 127, 245, 20).astype(np.uint8)
        src = np.float32([[0, 0], [img.shape[1], 0], [0, img.shape[0]]])
        dst = np.float32([world_to_ground(*sheet_to_world(b, (p[0] / bp, p[1] / bp))) for p in src])
        A = cv2.getAffineTransform(src, dst)
        warped = cv2.warpAffine(img, A, (W, H), flags=cv2.INTER_AREA, borderValue=0)
        mask = cv2.warpAffine(np.full_like(img, 255), A, (W, H), flags=cv2.INTER_NEAREST, borderValue=0)
        g[mask > 0] = warped[mask > 0]
    if damaged:
        damage(g, boards, rng)
    return g


def camera_pose(cam, car_w, car_l, height, pitch):
    """Camera centre in the car frame and its rotation, camera -> world."""
    _, mx, my = POSITIONS[cam["position"]]
    C = np.array([mx * car_w / 2, my * car_l / 2, height])
    psi, phi = math.radians(cam["facing"]), math.radians(pitch)
    forward = np.array([math.cos(psi) * math.cos(phi), math.sin(psi) * math.cos(phi), -math.sin(phi)])
    right = np.array([math.sin(psi), -math.cos(psi), 0.0])
    down = np.cross(forward, right)
    return C, np.stack([right, down, forward], axis=1)


def pixel_rays(K, D, fisheye, size):
    """Unit ray in camera coordinates for every pixel, shape (H, W, 3)."""
    W, H = size
    xs, ys = np.meshgrid(np.arange(W, dtype=np.float64), np.arange(H, dtype=np.float64))
    x = (xs - K[0, 2]) / K[0, 0]
    y = (ys - K[1, 2]) / K[1, 1]
    if fisheye:
        # cv2.fisheye.undistortPoints stops at 90 degrees; invert theta_d -> theta with Newton.
        thd = np.hypot(x, y)
        th = thd.copy()
        for _ in range(20):
            t2 = th * th
            f = th * (1 + t2 * (D[0] + t2 * (D[1] + t2 * (D[2] + t2 * D[3])))) - thd
            th -= f / (1 + t2 * (3 * D[0] + t2 * (5 * D[1] + t2 * (7 * D[2] + t2 * 9 * D[3]))))
        phi = np.arctan2(y, x)
        return np.stack([np.sin(th) * np.cos(phi), np.sin(th) * np.sin(phi), np.cos(th)], -1)
    pts = np.stack([xs.ravel(), ys.ravel()], 1).reshape(-1, 1, 2)
    u = cv2.undistortPoints(pts, K, D).reshape(H, W, 2)
    ray = np.concatenate([u, np.ones((H, W, 1))], -1)
    return ray / np.linalg.norm(ray, axis=-1, keepdims=True)


def render(ground, rays, C, R):
    dw = rays @ R.T
    with np.errstate(divide="ignore", invalid="ignore"):
        t = -C[2] / np.where(dw[..., 2] < -1e-9, dw[..., 2], np.nan)
    gx, gy = world_to_ground(C[0] + t * dw[..., 0], C[1] + t * dw[..., 1])
    gx = np.where(np.isfinite(gx), gx, -1).astype(np.float32)
    gy = np.where(np.isfinite(gy), gy, -1).astype(np.float32)
    return cv2.remap(ground, gx, gy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=120)


def project(K, D, fisheye, C, R, xy):
    """Ground points (N, 2) to pixels through the true camera; also each point's depth."""
    P = np.c_[xy, np.zeros(len(xy))]
    Pc = (P - C) @ R
    proj = cv2.fisheye.projectPoints if fisheye else cv2.projectPoints
    out, _ = proj(Pc.reshape(-1, 1, 3), np.zeros(3), np.zeros(3), K, D)
    return out.reshape(-1, 2), Pc[:, 2]


def write_lens_ini(path, kind, K, D, size):
    keys = ("k1", "k2", "k3", "k4") if kind == "fisheye" else ("k1", "k2", "p1", "p2", "k3")
    lines = [f"model = {kind}", f"fx = {K[0, 0]}", f"fy = {K[1, 1]}", f"cx = {K[0, 2]}", f"cy = {K[1, 2]}"]
    lines += [f"{k} = {float(v)!r}" for k, v in zip(keys, D)]
    lines += [f"calib_w = {size[0]}", f"calib_h = {size[1]}"]
    Path(path).write_text("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("layout", type=Path)
    ap.add_argument("--out", type=Path, default=Path("synth"))
    ap.add_argument("--lens", choices=sorted(LENSES), default="fisheye")
    ap.add_argument("--pitch", type=float, default=40.0, help="degrees down from horizontal")
    ap.add_argument("--height", type=float, default=0.9, help="camera height, metres")
    ap.add_argument("--size", default="3280x2464")
    ap.add_argument("--damage", action="store_true",
                    help="smudge two markers per ChArUco board and glare a corner of each square, "
                         "so some corners go undetected")
    args = ap.parse_args()

    size = tuple(int(v) for v in args.size.lower().split("x"))
    K = np.array(LENSES[args.lens]["K"], dtype=np.float64)
    K[:2] *= size[0] / 3280.0
    D = np.array(LENSES[args.lens]["D"])
    fisheye = args.lens == "fisheye"

    layout = read_layout(args.layout)
    args.out.mkdir(parents=True, exist_ok=True)
    ground = ground_image(layout["boards"], damaged=args.damage)
    rays = pixel_rays(K, D, fisheye, size)
    cams = {}
    for cam in layout["cameras"]:
        C, R = camera_pose(cam, layout["car_width"], layout["car_length"], args.height, args.pitch)
        cv2.imwrite(str(args.out / f"{cam['position']}.png"), render(ground, rays, C, R))
        cams[cam["position"]] = dict(C=C.tolist(), R=R.tolist())
        print(f"{cam['position']}: at ({C[0]:.2f}, {C[1]:.2f}) m facing {cam['facing']:.0f} deg")
    for lens in {c["lens"] for c in layout["cameras"] if c["lens"]}:
        write_lens_ini(args.out / f"{lens}-lens.ini", args.lens, K, D, size)
    json.dump(dict(K=K.tolist(), D=D.tolist(), fisheye=fisheye, size=size, cams=cams),
              open(args.out / "truth.json", "w"), indent=1)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
