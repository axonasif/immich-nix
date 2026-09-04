#!/usr/bin/env python3
"""Exercise every real ML model family through the deployed HTTP service."""

from __future__ import annotations

import json
import math
import os
import sys
from pathlib import Path

import httpx


BASE_URL = os.environ.get("IMMICH_ML_URL", "http://127.0.0.1:3005")
IMAGE = Path(os.environ["IMMICH_SMOKE_IMAGE"])
TIMEOUT = httpx.Timeout(900)
CLIP_MODEL = os.environ.get("IMMICH_TEST_SMART_SEARCH_MODEL", "ViT-SO400M-16-SigLIP2-384__webli")
FACE_MODEL = os.environ.get("IMMICH_TEST_FACE_MODEL", "buffalo_l")
OCR_MODEL = os.environ.get("IMMICH_TEST_OCR_MODEL", "PP-OCRv5_server")


def predict(entries: dict, *, image: Path | None = None, text: str | None = None) -> dict:
    data = {"entries": json.dumps(entries)}
    files = None
    if text is not None:
        data["text"] = text
    if image is not None:
        files = {"image": (image.name, image.read_bytes())}

    response = httpx.post(f"{BASE_URL}/predict", data=data, files=files, timeout=TIMEOUT)
    if response.status_code != 200:
        raise AssertionError(f"ML request failed ({response.status_code}): {response.text}")
    result = response.json()
    if not isinstance(result, dict):
        raise AssertionError(f"ML response is not an object: {result!r}")
    return result


def embedding(result: dict) -> list[float]:
    value = result.get("clip")
    if not isinstance(value, str):
        raise AssertionError("CLIP response did not contain a serialized embedding")
    vector = json.loads(value)
    if len(vector) != 1152 or not all(math.isfinite(item) for item in vector):
        raise AssertionError("SO400M CLIP embedding is not a finite 1152-element vector")
    return vector


def main() -> None:
    print("[test] ML: textual CLIP inference", flush=True)
    embedding(
        predict(
            {"clip": {"textual": {"modelName": CLIP_MODEL}}},
            text="a mountain landscape",
        )
    )

    print("[test] ML: visual CLIP inference", flush=True)
    embedding(
        predict(
            {"clip": {"visual": {"modelName": CLIP_MODEL}}},
            image=IMAGE,
        )
    )

    print("[test] ML: face detection and recognition", flush=True)
    face = predict(
        {
            "facial-recognition": {
                "detection": {"modelName": FACE_MODEL, "options": {"minScore": 0.5}},
                "recognition": {"modelName": FACE_MODEL},
            }
        },
        image=IMAGE,
    )
    faces = face.get("facial-recognition")
    if not isinstance(faces, list) or not faces:
        raise AssertionError("face fixture produced no detections")
    for detected in faces:
        vector = json.loads(detected["embedding"])
        if len(vector) != 512 or not all(math.isfinite(item) for item in vector):
            raise AssertionError("face recognition returned an invalid embedding")

    print("[test] ML: OCR detection and recognition", flush=True)
    ocr = predict(
        {
            "ocr": {
                "detection": {
                    "modelName": OCR_MODEL,
                    "options": {"minScore": 0.3, "maxResolution": 736},
                },
                "recognition": {"modelName": OCR_MODEL, "options": {"minScore": 0.5}},
            }
        },
        image=IMAGE,
    )
    recognized = ocr.get("ocr")
    if not isinstance(recognized, dict) or not recognized.get("text"):
        raise AssertionError("OCR fixture produced no recognized text")

    print("[test] real ML inference passed", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"[test] {error}", file=sys.stderr)
        raise
