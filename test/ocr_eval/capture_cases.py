"""Turns photos of real prescriptions into OCR eval cases.

Sends each photo to the backend's vision OCR endpoint (Gemini, falling
back to Groq) and writes test/ocr_eval/cases/real_<name>.json with the
exact text the AI read. You then fill in "expected" with what is REALLY
written on the paper, and run:

    flutter test test/ocr_eval/ocr_eval_test.dart

Usage (backend running, e.g. `php artisan serve`):

    set OCR_EVAL_TOKEN=<a dispenser's Sanctum token>
    python test/ocr_eval/capture_cases.py photos\\rx1.jpg photos\\rx2.jpg

Options:
    --api http://127.0.0.1:8000/api   backend base URL (default shown)

Existing case files are never overwritten. Only the transcription is
stored, never the photo itself; still, these are real patient records —
blank out or change patient names before committing them anywhere.
Python standard library only.
"""

import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

CASES_DIR = Path(__file__).parent / "cases"
ENGINES = ["gemini-scan", "groq-scan"]


def post_image(url: str, token: str, image: Path) -> dict:
    boundary = uuid.uuid4().hex
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="image"; filename="{image.name}"\r\n'
        "Content-Type: image/jpeg\r\n\r\n"
    ).encode() + image.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    request = urllib.request.Request(
        url,
        data=body,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read())
        except ValueError:
            return {"success": False, "error": f"HTTP {e.code}"}


def main(argv: list[str]) -> int:
    api = "http://127.0.0.1:8000/api"
    if "--api" in argv:
        i = argv.index("--api")
        api = argv[i + 1].rstrip("/")
        del argv[i : i + 2]
    images = [Path(a) for a in argv]
    token = os.environ.get("OCR_EVAL_TOKEN", "")
    if not images or not token:
        print(__doc__)
        return 2

    CASES_DIR.mkdir(exist_ok=True)
    for image in images:
        out = CASES_DIR / f"real_{image.stem}.json"
        if out.exists():
            print(f"skip  {image.name}: {out.name} already exists")
            continue

        reply, engine = None, None
        for engine in ENGINES:
            reply = post_image(f"{api}/ocr/{engine}", token, image)
            if reply.get("success"):
                break
            print(f"      {image.name}: {engine} failed ({reply.get('error')})")
        if not reply or not reply.get("success"):
            print(f"FAIL  {image.name}: no engine could read it")
            continue

        case = {
            "id": f"R_{image.stem}",
            "source": "real",
            "note": f"Captured from {image.name} via {engine}. Fill in 'expected'.",
            "raw_text": reply["text"],
            "lines": reply.get("lines", []),
            "expected": [
                {"name": "TODO medicine as written on the paper", "dosage": "", "quantity": ""}
            ],
        }
        out.write_text(json.dumps(case, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"ok    {image.name} -> {out.name} ({engine})")
        print("      " + reply["text"].replace("\n", "\n      "))

    print("\nNext: open each real_*.json, replace the TODO entry in 'expected' with the")
    print("medicines actually written on the paper, then run the eval.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
