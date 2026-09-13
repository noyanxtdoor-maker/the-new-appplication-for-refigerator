#!/usr/bin/env python3
"""VS16 M7 — on-device compass tap verifier.

Runs the whole gate on the real handset:
  1. start the app, open Maps, wait for the probe's non-north camera,
  2. capture the pre-tap frame and locate the visible compass needle,
  3. tap the compass with real Android input events,
  4. capture the post-tap frame and read the bearing frames the SDK reports.

Usage: python verify.py <label> [tap_x tap_y]
"""
import re
import subprocess
import sys
import time

import numpy as np
from PIL import Image

ADB = r"C:\Users\sherl\AppData\Local\Android\Sdk\platform-tools\adb.exe"
PKG = "com.nexttransfer.rmplanner"
MAP_TAB = (945, 2100)
CORNER = (0, 320, 260, 500)


def shell(cmd):
    return subprocess.run([ADB, "shell", cmd], capture_output=True, text=True).stdout


def screencap(path):
    with open(path, "wb") as handle:
        subprocess.run([ADB, "exec-out", "screencap", "-p"], stdout=handle)


def flutter_log():
    return subprocess.run(
        [ADB, "logcat", "-d", "-s", "flutter"], capture_output=True, text=True
    ).stdout


def frames():
    """Every camera frame the app recorded, oldest first."""
    out = []
    for line in flutter_log().splitlines():
        match = re.search(
            r"(\d\d:\d\d:\d\d\.\d+).*NTProbe camera bearing=([-\d.]+) tilt=([-\d.]+) "
            r"zoom=([-\d.]+) target=([-\d.]+),([-\d.]+)",
            line,
        )
        if match:
            out.append(
                {
                    "t": match.group(1),
                    "bearing": float(match.group(2)),
                    "tilt": float(match.group(3)),
                    "zoom": float(match.group(4)),
                    "target": (match.group(5), match.group(6)),
                }
            )
    return out


def intents():
    return len(re.findall(r"NTProbe user-intent claimed", flutter_log()))


def compass(path):
    """Red needle pixels and centroid inside the map's top-left corner."""
    img = np.asarray(Image.open(path).convert("RGB").crop(CORNER)).astype(int)
    r, g, b = img[:, :, 0], img[:, :, 1], img[:, :, 2]
    mask = (r > 140) & (r - g > 55) & (r - b > 45)
    if int(mask.sum()) == 0:
        return None
    ys, xs = np.nonzero(mask)
    return {"px": int(mask.sum()), "x": float(xs.mean()) + CORNER[0], "y": float(ys.mean()) + CORNER[1]}


def wait_for_bearing(value=40.0, timeout=40.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        seen = frames()
        if seen and abs(seen[-1]["bearing"] - value) < 0.01:
            return seen[-1]
        time.sleep(1.0)
    return None


def main():
    label = sys.argv[1] if len(sys.argv) > 1 else "run"
    fixed_tap = (int(sys.argv[2]), int(sys.argv[3])) if len(sys.argv) > 3 else None
    shell(f"am force-stop {PKG}")
    shell("logcat -c")
    shell(f"am start -W -n {PKG}/.MainActivity >/dev/null")
    time.sleep(9)
    shell(f"input tap {MAP_TAB[0]} {MAP_TAB[1]}")
    settled = wait_for_bearing()
    if settled is None:
        print("INVALID: probe never reached bearing 40 (app state or interference)")
        for frame in frames()[-6:]:
            print("   ", frame)
        return
    print(f"compass located phase: probe settled at bearing={settled['bearing']:.2f}")

    pre = f"{label}_pre.png"
    screencap(pre)
    found = compass(pre)
    if found is None:
        print("INVALID: no compass needle visible at bearing 40 before the tap")
        return
    before = frames()[-1]
    print(
        f"NEEDLE VISIBLE = YES ({found['px']} red px at "
        f"{found['x']:.0f},{found['y']:.0f})"
    )
    print(
        f"BEARING BEFORE TAP = {before['bearing']:.2f} "
        f"tilt={before['tilt']:.2f} zoom={before['zoom']:.3f} target={before['target']}"
    )

    if fixed_tap:
        tap = fixed_tap
    else:
        # The needle is painted inside the compass control: its centroid is a
        # safe tap target that tracks the icon wherever it rotates.
        tap = (int(round(found["x"])), int(round(found["y"])))
    intents_before = intents()
    print(f"tapping compass at ({tap[0]},{tap[1]}) at {time.strftime('%H:%M:%S')}")
    shell(f"input motionevent DOWN {tap[0]} {tap[1]}")
    time.sleep(0.09)
    shell(f"input motionevent UP {tap[0]} {tap[1]}")
    time.sleep(3.0)
    post = f"{label}_post.png"
    screencap(post)
    after = frames()[-1]
    after_found = compass(post)
    print(
        f"BEARING AFTER TAP = {after['bearing']:.2f} "
        f"tilt={after['tilt']:.2f} zoom={after['zoom']:.3f} target={after['target']}"
    )
    print(f"needle after tap: {'PRESENT' if after_found else 'ABSENT (north-up)'}")
    print(
        f"tap deliveries observed by Dart = {intents() - intents_before} "
        f"(interference frames: {len(frames())})"
    )
    target_same = before["target"] == after["target"]
    zoom_same = abs(before["zoom"] - after["zoom"]) < 1e-6
    print(
        f"TARGET PRESERVED = {'YES' if target_same else 'NO'} "
        f"ZOOM PRESERVED = {'YES' if zoom_same else 'NO'}"
    )
    print("VERDICT = " + ("PASS" if abs(after["bearing"]) < 0.01 else "FAIL"))


if __name__ == "__main__":
    main()
