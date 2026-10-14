#!/usr/bin/env python3
"""Fix the AI accounts' photos that are badly framed. Good photos are NOT touched.

Only one problem is corrected: a face that lands LOW in the window the Discover
card shows (the card is nearly square, so a tall selfie is shown zoomed in, with
the face huge and cut at the bottom). Those photos get a 3:4 crop that raises the
face and shows more of the picture. Everything else (the large majority) and every
photo without a detectable face stays exactly as it is.


    pip install opencv-python-headless numpy requests

    python admin/scripts/recrop_ai_photos.py                 # PREVIEW: local before/after images, nothing uploaded
    python admin/scripts/recrop_ai_photos.py --limit 60      # preview 60 photos
    python admin/scripts/recrop_ai_photos.py --go            # apply to every AI account
    python admin/scripts/recrop_ai_photos.py --go --limit 20 # apply to 20 only (test)

What it does, per AI account (profiles.is_ai = true only, never a real user):
  1. downloads its photo,
  2. LOCATES the face (OpenCV YuNet detector: a box position, no identification),
  3. crops a 3:4 portrait, as loose as possible, so the face centre sits around
     40 % from the top (dead centre would be 50 %) with the hair never cut,
  4. uploads it under a NEW key `ai/<id>/crop<timestamp>.jpg`, points avatar_url /
     discover_photo_url / photos at it, then deletes the old file.
A photo with no detected face is left untouched (and not retried).
Your original files are still in your photo folders: nothing here is the only copy.

Uses SUPABASE_SERVICE_ROLE_KEY from admin/.env.local.
"""
import argparse
import json
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import cv2
import numpy as np
import requests

cv2.setNumThreads(1)  # we already run several photos in parallel: no oversubscription

HERE = Path(__file__).resolve().parent
BUCKET = "avatars"
OUT_W, OUT_H = 1080, 1440  # 3:4 portrait
FACE_Y = 0.40              # face centre, from the top (0.5 = dead centre)
HEADROOM = 0.5             # keep at least this many face-heights above the face box
MIN_SCORE = 0.80           # YuNet confidence below which a detection is ignored
CARD_ASPECT = 0.90         # Discover card width / height (measured on a phone screenshot)
CARD_ALIGN_Y = -0.6        # the card's Image alignment (discover_screen.dart)
LOW_REL = 0.62             # face centre lower than this in the card window: needs fixing
MIN_GAIN = 0.08            # ...and only if the crop moves it up by at least this much
MIN_FACE_H = 0.10          # ignore "faces" smaller than this share of the image height
NOFACE_FILE = HERE / ".recrop_noface.json"
PREVIEW_DIR = HERE / "recrop_preview"


def load_env():
    env = {}
    for line in (HERE.parent / ".env.local").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


ENV = load_env()
URL = ENV.get("NEXT_PUBLIC_SUPABASE_URL", "").rstrip("/")
KEY = ENV.get("SUPABASE_SERVICE_ROLE_KEY", "")
if not URL or not KEY:
    sys.exit("Missing Supabase URL / service-role key in admin/.env.local")
HDR = {"apikey": KEY, "Authorization": f"Bearer {KEY}"}

_tls = threading.local()


MODEL = HERE / "face_detection_yunet_2023mar.onnx"
MODEL_URL = ("https://github.com/opencv/opencv_zoo/raw/main/models/"
             "face_detection_yunet/face_detection_yunet_2023mar.onnx")
_model_lock = threading.Lock()


def ensure_model():
    """YuNet (OpenCV's small face detector, 230 KB): downloaded once next to the script."""
    with _model_lock:
        if not MODEL.exists() or MODEL.stat().st_size < 100_000:
            print(f"Downloading the face detection model to {MODEL.name} ...")
            r = requests.get(MODEL_URL, timeout=120)
            r.raise_for_status()
            MODEL.write_bytes(r.content)


def detector():
    """One detector per thread (the object is not thread-safe)."""
    if not hasattr(_tls, "d"):
        ensure_model()
        _tls.d = cv2.FaceDetectorYN.create(
            str(MODEL), "", (320, 320), score_threshold=MIN_SCORE, nms_threshold=0.3, top_k=10)
    return _tls.d


def find_face(img):
    """The most confident face as (x, y, w, h) in image pixels, or None.
    Only the position of the face is computed: nobody is identified."""
    ih, iw = img.shape[:2]
    scale = min(1.0, 960.0 / max(ih, iw))
    small = cv2.resize(img, (round(iw * scale), round(ih * scale))) if scale < 1 else img
    det = detector()
    det.setInputSize((small.shape[1], small.shape[0]))
    _, faces = det.detect(small)
    if faces is None or len(faces) == 0:
        return None
    f = max(faces, key=lambda r: r[-1])  # highest confidence, not "largest"
    x, y, w, h = f[0] / scale, f[1] / scale, f[2] / scale, f[3] / scale
    # a box that pokes out of the image is clipped
    x, y = max(0.0, x), max(0.0, y)
    w, h = min(w, iw - x), min(h, ih - y)
    return (x, y, w, h) if w > 0 and h > 0 else None


def plan_crop(iw, ih, face):
    fx, fy, fw, fh = face
    cx, cy = fx + fw / 2, fy + fh / 2
    # The biggest 3:4 window that fits: crop as little as possible.
    # Never zoom in beyond that: a false detection would then blow up a nose.
    ch = min(ih, iw * 4 / 3)
    cw = ch * 3 / 4
    top = cy - FACE_Y * ch                 # face centre a little above the middle
    top = min(top, fy - HEADROOM * fh)     # ...but never cut the hair
    top = min(max(top, 0), ih - ch)
    left = min(max(cx - cw / 2, 0), iw - cw)
    return int(round(left)), int(round(top)), int(round(cw)), int(round(ch))


def card_rel(iw, ih, cy):
    """Where the face centre lands INSIDE the window the Discover card shows
    (0 = top edge, 1 = bottom edge). The card is nearly square and fills it with
    BoxFit.cover, alignment y = -0.6 (lib/screens/discover_screen.dart), so a
    tall photo only shows its top ~60 %, starting a little below the top."""
    wh = iw / CARD_ASPECT  # visible height, in image pixels
    if wh >= ih:           # photo wider than the card: its full height is shown
        return cy / ih
    top = (ih - wh) * (1 + CARD_ALIGN_Y) / 2
    return (cy - top) / wh


def fix_photo(img):
    """(status, new image or None). status: noface / fine / fixed.
    A photo is only changed when its face lands low in the card window (like a
    tall selfie whose face sits at 57 % of the height: on the card it ends up at
    the bottom, huge and cut). The fix is a 3:4 crop that raises the face; it also
    shows MORE of the photo, so it zooms out. Everything else is left untouched."""
    face = find_face(img)
    if face is None:
        return "noface", None
    ih, iw = img.shape[:2]
    if face[3] / ih < MIN_FACE_H:  # a speck: probably not a face (hair, fabric...)
        return "noface", None
    cy = face[1] + face[3] / 2
    if card_rel(iw, ih, cy) <= LOW_REL:
        return "fine", None
    l, t, w, h = plan_crop(iw, ih, face)
    if card_rel(w, h, cy - t) > card_rel(iw, ih, cy) - MIN_GAIN:  # would not really help
        return "fine", None
    crop = img[t:t + h, l:l + w]
    scale = min(1.0, OUT_W / max(w, 1))
    if scale < 1:
        crop = cv2.resize(crop, (round(w * scale), round(h * scale)), interpolation=cv2.INTER_AREA)
    return "fixed", crop


def fetch_ai_profiles(skip_ids):
    out, offset = [], 0
    while True:
        r = requests.get(
            f"{URL}/rest/v1/profiles",
            headers=HDR,
            params={
                "select": "id,discover_photo_url,avatar_url,photos",
                "is_ai": "eq.true",
                "order": "id.asc",
                "limit": 1000,
                "offset": offset,
            },
            timeout=60,
        )
        r.raise_for_status()
        rows = r.json()
        out += rows
        if len(rows) < 1000:
            break
        offset += 1000
    todo = []
    for p in out:
        u = (p.get("discover_photo_url") or p.get("avatar_url") or "").strip()
        if not u or "/crop" in u or p["id"] in skip_ids:
            continue
        todo.append((p["id"], u))
    return todo


def decode(content):
    return cv2.imdecode(np.frombuffer(content, np.uint8), cv2.IMREAD_COLOR)


def process(args, item):
    pid, url = item
    try:
        r = requests.get(url, timeout=40)
        r.raise_for_status()
        img = decode(r.content)
        if img is None:
            return pid, "unreadable", None
        status, crop = fix_photo(img)
        if crop is None:  # noface / fine: the photo is left exactly as it is
            return pid, status, None
        if not args.go:  # preview: save side by side, upload nothing
            PREVIEW_DIR.mkdir(exist_ok=True)
            h = 600
            a = cv2.resize(img, (int(img.shape[1] * h / img.shape[0]), h))
            b = cv2.resize(crop, (int(crop.shape[1] * h / crop.shape[0]), h))
            ok, buf = cv2.imencode(".jpg", np.hstack([a, b]), [cv2.IMWRITE_JPEG_QUALITY, 85])
            (PREVIEW_DIR / f"{status}_{pid}.jpg").write_bytes(buf.tobytes())
            return pid, status, None
        ok, buf = cv2.imencode(".jpg", crop, [cv2.IMWRITE_JPEG_QUALITY, 85])
        key = f"ai/{pid}/crop{int(time.time() * 1000)}.jpg"
        up = requests.post(
            f"{URL}/storage/v1/object/{BUCKET}/{key}",
            headers={**HDR, "Content-Type": "image/jpeg", "x-upsert": "true"},
            data=buf.tobytes(),
            timeout=60,
        )
        up.raise_for_status()
        new_url = f"{URL}/storage/v1/object/public/{BUCKET}/{key}"
        pr = requests.patch(
            f"{URL}/rest/v1/profiles",
            headers={**HDR, "Content-Type": "application/json", "Prefer": "return=minimal"},
            params={"id": f"eq.{pid}"},
            json={
                "avatar_url": new_url,
                "discover_photo_url": new_url,
                "photos": [new_url],
                "updated_at": datetime.now(timezone.utc).isoformat(),
            },
            timeout=30,
        )
        pr.raise_for_status()
        m = re.search(rf"/object/public/{BUCKET}/(.+)$", url)
        if m:  # the old file, only after the profile points at the new one
            requests.delete(
                f"{URL}/storage/v1/object/{BUCKET}",
                headers={**HDR, "Content-Type": "application/json"},
                json={"prefixes": [m.group(1)]},
                timeout=30,
            )
        return pid, f"applied_{status}", None
    except Exception as e:  # noqa: BLE001
        return pid, "error", str(e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--go", action="store_true", help="apply (default: local preview only)")
    ap.add_argument("--limit", type=int, default=0, help="max photos (default: 24 in preview, all with --go)")
    ap.add_argument("--workers", type=int, default=6)
    args = ap.parse_args()

    noface = set(json.loads(NOFACE_FILE.read_text())) if NOFACE_FILE.exists() else set()
    todo = fetch_ai_profiles(noface)
    limit = args.limit or (0 if args.go else 24)
    if limit:
        todo = todo[:limit]
    print(f"{len(todo)} AI photo(s) to {'re-crop' if args.go else 'preview'}"
          f" ({len(noface)} previously without a detectable face are skipped).")
    if not todo:
        return

    counts = {}
    with ThreadPoolExecutor(args.workers) as ex:
        for i, (pid, status, err) in enumerate(ex.map(lambda it: process(args, it), todo), 1):
            counts[status] = counts.get(status, 0) + 1
            if status in ("noface", "fine"):
                noface.add(pid)  # settled: no change needed, never re-checked
            if status == "error":
                print(f"x {pid}: {err}")
            if i % 50 == 0:
                print(f"... {i}/{len(todo)} {counts}")
    if args.go:  # a preview never settles anything: thresholds can still change
        NOFACE_FILE.write_text(json.dumps(sorted(noface)))
    print(f"\n{counts}")
    print("fine = already good (untouched) · noface = no face found (untouched) · "
          "fixed = face raised / photo zoomed out")
    if not args.go:
        print(f"Preview images of the ones that WOULD change (left = before, right = after): {PREVIEW_DIR}")
        print("Happy with them? Run again with --go.")


if __name__ == "__main__":
    main()
