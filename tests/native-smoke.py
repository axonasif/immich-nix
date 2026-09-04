#!/usr/bin/env python3
"""Black-box media lifecycle test for the assembled native Immich stack."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import httpx


BASE_URL = os.environ.get("IMMICH_TEST_BASE_URL", "http://127.0.0.1:2285/api")
CLI = Path(os.environ["IMMICH_TEST_CLI"])
FIXTURES = Path(os.environ["IMMICH_TEST_FIXTURES"])
STATE_PATH = Path(os.environ["IMMICH_TEST_STATE"])
MEDIA_DIR = Path(os.environ["IMMICH_MEDIA_DIR"]).resolve()
CLI_CONFIG = STATE_PATH.parent / "cli-config"
EMAIL = "native-test@immich.local"
PASSWORD = "native-test-password"
HTTP_TIMEOUT = httpx.Timeout(30)
FULL = os.environ.get("IMMICH_TEST_FULL") == "true"
PROCESSING_TIMEOUT = int(os.environ.get("IMMICH_TEST_TIMEOUT", "240"))
SMART_SEARCH_MODEL = os.environ.get("IMMICH_TEST_SMART_SEARCH_MODEL", "ViT-SO400M-16-SigLIP2-384__webli")
FACE_MODEL = os.environ.get("IMMICH_TEST_FACE_MODEL", "buffalo_l")
OCR_MODEL = os.environ.get("IMMICH_TEST_OCR_MODEL", "PP-OCRv5_server")


def fail(message: str) -> None:
    raise AssertionError(message)


def expect(response: httpx.Response, *statuses: int) -> httpx.Response:
    if response.status_code not in statuses:
        fail(f"{response.request.method} {response.request.url} returned {response.status_code}: {response.text}")
    return response


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def api_key(secret: str) -> dict[str, str]:
    return {"x-api-key": secret}


def login(client: httpx.Client) -> str:
    response = expect(client.post("/auth/login", json={"email": EMAIL, "password": PASSWORD}), 201)
    token = response.json().get("accessToken")
    if not isinstance(token, str) or not token:
        fail("login response did not contain an access token")
    return token


def run_cli(*args: str) -> str:
    command = [str(CLI), "-d", str(CLI_CONFIG), *args]
    result = subprocess.run(command, text=True, capture_output=True, timeout=PROCESSING_TIMEOUT)
    if result.returncode != 0:
        fail(f"CLI command failed ({' '.join(command)}):\n{result.stdout}\n{result.stderr}")
    return result.stdout


def search_asset(client: httpx.Client, token: str, name: str) -> dict[str, Any] | None:
    response = expect(
        client.post(
            "/search/metadata",
            headers=bearer(token),
            json={"originalFileName": name, "page": 1, "size": 10},
        ),
        200,
    )
    items = response.json().get("assets", {}).get("items", [])
    return next((item for item in items if item.get("originalFileName") == name), None)


def wait_for_asset(client: httpx.Client, token: str, name: str) -> dict[str, Any]:
    deadline = time.monotonic() + PROCESSING_TIMEOUT
    while time.monotonic() < deadline:
        asset = search_asset(client, token, name)
        if asset is not None and asset.get("hasMetadata") and asset.get("width") and asset.get("height"):
            return asset
        time.sleep(1)
    fail(f"timed out waiting for metadata extraction for {name}")


def wait_for_transcode(client: httpx.Client, token: str, name: str, asset_id: str) -> None:
    deadline = time.monotonic() + PROCESSING_TIMEOUT
    while time.monotonic() < deadline:
        response = expect(
            client.post(
                "/search/metadata",
                headers=bearer(token),
                json={"originalFileName": name, "isEncoded": True, "page": 1, "size": 10},
            ),
            200,
        )
        items = response.json().get("assets", {}).get("items", [])
        if any(item.get("id") == asset_id for item in items):
            return
        time.sleep(2)
    fail(f"timed out waiting for video transcoding for {name}")


def wait_for_media(client: httpx.Client, secret: str, path: str) -> bytes:
    deadline = time.monotonic() + PROCESSING_TIMEOUT
    last_status = 0
    while time.monotonic() < deadline:
        response = client.get(path, headers=api_key(secret))
        last_status = response.status_code
        if response.status_code in (200, 206) and response.content:
            return response.content
        time.sleep(2)
    fail(f"timed out waiting for {path}; last HTTP status was {last_status}")


def configure_ml(client: httpx.Client, token: str) -> None:
    config = expect(client.get("/system-config", headers=bearer(token)), 200).json()
    machine_learning = config["machineLearning"]
    machine_learning["enabled"] = True
    machine_learning["clip"]["enabled"] = True
    machine_learning["clip"]["modelName"] = SMART_SEARCH_MODEL
    machine_learning["facialRecognition"].update(
        {"enabled": True, "modelName": FACE_MODEL, "minScore": 0.5, "minFaces": 1}
    )
    machine_learning["ocr"]["enabled"] = True
    machine_learning["ocr"]["modelName"] = OCR_MODEL
    updated = expect(client.put("/system-config", headers=bearer(token), json=config), 200).json()
    selected = updated["machineLearning"]
    if selected["clip"]["modelName"] != SMART_SEARCH_MODEL:
        fail("server did not retain the requested smart-search model")
    if selected["facialRecognition"]["modelName"] != FACE_MODEL:
        fail("server did not retain the requested face-recognition model")
    if selected["ocr"]["modelName"] != OCR_MODEL:
        fail("server did not retain the requested OCR model")


def wait_for_ml_features(client: httpx.Client, token: str, asset_id: str) -> None:
    deadline = time.monotonic() + PROCESSING_TIMEOUT
    queue_names = ("smartSearch", "faceDetection", "facialRecognition", "ocr")
    while time.monotonic() < deadline:
        queues_response = client.get("/jobs", headers=bearer(token))
        if queues_response.status_code == 200:
            queues = queues_response.json()
            failed = {name: queues[name]["jobCounts"]["failed"] for name in queue_names}
            if any(failed.values()):
                fail(f"machine-learning jobs failed: {failed}")
            if all(
                not queues[name]["jobCounts"]["active"] and not queues[name]["jobCounts"]["waiting"]
                for name in queue_names
            ):
                break
        time.sleep(3)
    else:
        fail("timed out waiting for Immich machine-learning queues")

    asset = expect(client.get(f"/assets/{asset_id}", headers=bearer(token)), 200).json()
    if not asset.get("people"):
        fail("buffalo_l produced no recognized person for the screenshot fixture")

    ocr_response = expect(
        client.post(
            "/search/metadata",
            headers=bearer(token),
            json={"ocr": "immich", "page": 1, "size": 10},
        ),
        200,
    )
    ocr_items = ocr_response.json().get("assets", {}).get("items", [])
    if not any(item.get("id") == asset_id for item in ocr_items):
        fail("PP-OCRv5_server output was not searchable")

    smart_response = expect(
        client.post(
            "/search/smart",
            headers=bearer(token),
            json={"query": "photo management application interface", "page": 1, "size": 10},
            timeout=PROCESSING_TIMEOUT,
        ),
        200,
    )
    smart_items = smart_response.json().get("assets", {}).get("items", [])
    if not any(item.get("id") == asset_id for item in smart_items):
        fail("SO400M smart search did not return the screenshot fixture")


def verify_download(client: httpx.Client, secret: str, asset: dict[str, Any], fixture: Path) -> None:
    content = expect(client.get(f"/assets/{asset['id']}/original", headers=api_key(secret)), 200).content
    if hashlib.sha256(content).digest() != hashlib.sha256(fixture.read_bytes()).digest():
        fail(f"downloaded original does not match {fixture.name}")


def assert_native_path(asset: dict[str, Any]) -> None:
    original = Path(asset["originalPath"]).resolve()
    if not original.is_relative_to(MEDIA_DIR):
        fail(f"asset escaped the native media directory: {original}")
    if not original.is_file():
        fail(f"stored original is missing: {original}")


def create() -> None:
    photo = FIXTURES / "native-photo.jpg"
    video = FIXTURES / "native-video.mp4"
    screenshot = FIXTURES / "immich-screenshot.png"
    with httpx.Client(base_url=BASE_URL, timeout=HTTP_TIMEOUT, follow_redirects=True) as client:
        expect(client.post("/auth/admin-sign-up", json={"email": EMAIL, "name": "Native Test", "password": PASSWORD}), 201)
        token = login(client)
        if FULL:
            configure_ml(client, token)
        key_response = expect(
            client.post("/api-keys", headers=bearer(token), json={"name": "native-test", "permissions": ["all"]}),
            201,
        ).json()
        secret = key_response.get("secret")
        if not isinstance(secret, str) or not secret:
            fail("API-key response did not contain a secret")

        login_output = run_cli("login", BASE_URL.removesuffix("/api") + "/", secret)
        if EMAIL not in login_output:
            fail("deployed CLI did not confirm the expected login")
        server_info = run_cli("server-info")
        if "Server Info" not in server_info:
            fail("deployed CLI did not return server information")

        fixtures = (photo, video, screenshot) if FULL else (photo, video)
        upload_output = run_cli("upload", "--no-progress", "-c", "1", *(str(path) for path in fixtures))
        if f"Successfully uploaded {len(fixtures)} new assets" not in upload_output:
            fail(f"deployed CLI did not report {len(fixtures)} uploads:\n{upload_output}")

        assets: list[dict[str, Any]] = []
        for fixture in fixtures:
            asset = wait_for_asset(client, token, fixture.name)
            assert_native_path(asset)
            verify_download(client, secret, asset, fixture)
            wait_for_media(client, secret, f"/assets/{asset['id']}/thumbnail")
            assets.append(asset)

        video_asset = next(asset for asset in assets if asset["originalFileName"] == video.name)
        wait_for_transcode(client, token, video.name, video_asset["id"])
        wait_for_media(client, secret, f"/assets/{video_asset['id']}/video/playback")
        if FULL:
            screenshot_asset = next(asset for asset in assets if asset["originalFileName"] == screenshot.name)
            wait_for_ml_features(client, token, screenshot_asset["id"])

    STATE_PATH.write_text(json.dumps({"apiKey": secret, "assets": assets}, indent=2))
    print("[test] public API and deployed CLI media lifecycle passed", flush=True)


def verify() -> None:
    state = json.loads(STATE_PATH.read_text())
    secret = state["apiKey"]
    run_cli("server-info")
    with httpx.Client(base_url=BASE_URL, timeout=HTTP_TIMEOUT, follow_redirects=True) as client:
        for saved in state["assets"]:
            fixture = FIXTURES / saved["originalFileName"]
            asset = expect(client.get(f"/assets/{saved['id']}", headers=api_key(secret)), 200).json()
            assert_native_path(asset)
            verify_download(client, secret, asset, fixture)
            wait_for_media(client, secret, f"/assets/{asset['id']}/thumbnail")
    print("[test] database and media survived a complete restart", flush=True)


def delete() -> None:
    state = json.loads(STATE_PATH.read_text())
    secret = state["apiKey"]
    assets = state["assets"]
    ids = [asset["id"] for asset in assets]
    originals = [Path(asset["originalPath"]) for asset in assets]
    with httpx.Client(base_url=BASE_URL, timeout=HTTP_TIMEOUT, follow_redirects=True) as client:
        expect(client.request("DELETE", "/assets", headers=api_key(secret), json={"ids": ids, "force": True}), 204)
        deadline = time.monotonic() + PROCESSING_TIMEOUT
        while time.monotonic() < deadline:
            responses = [client.get(f"/assets/{asset_id}", headers=api_key(secret)) for asset_id in ids]
            if all(response.status_code in (400, 404) for response in responses) and all(
                not path.exists() for path in originals
            ):
                break
            time.sleep(1)
        else:
            fail("force-deleted assets or their stored originals were not removed")
    run_cli("logout")
    print("[test] asset records and physical originals were deleted", flush=True)


def main() -> None:
    actions = {"create": create, "verify": verify, "delete": delete}
    if len(sys.argv) != 2 or sys.argv[1] not in actions:
        raise SystemExit(f"usage: {sys.argv[0]} <{'|'.join(actions)}>")
    actions[sys.argv[1]]()


if __name__ == "__main__":
    main()
