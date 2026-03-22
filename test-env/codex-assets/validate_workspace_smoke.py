#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path


EXPECTED_SHARED_INPUTS = [
    "./.spiderweb/shared_data/world_seed.json",
    "./.spiderweb/shared_data/items_seed.json",
    "./.spiderweb/shared_data/puzzle_seed.json",
]

EXPECTED_REQUIRED_SERVICES = [
    "home",
    "mounts",
    "workers",
    "terminal",
    "git",
    "search_code",
    "library",
    "events",
]


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def emit(output_path: Path | None, payload: dict) -> int:
    encoded = json.dumps(payload, indent=2, sort_keys=True)
    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(encoded + "\n", encoding="utf-8")
    print(encoded)
    return 0 if payload.get("ok") else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--shared-data", required=True)
    parser.add_argument("--output")
    args = parser.parse_args()

    workspace = Path(args.workspace).resolve()
    shared_data = Path(args.shared_data).resolve()
    output_path = None
    if args.output:
        requested_output = Path(args.output)
        output_path = requested_output if requested_output.is_absolute() else workspace / requested_output

    result_path = workspace / "smoke_result.json"
    notes_path = workspace / "smoke_notes.txt"
    readme_path = workspace / "README.md"

    checks: list[dict] = []
    for label, path in (
        ("smoke_result.json", result_path),
        ("smoke_notes.txt", notes_path),
        ("README.md", readme_path),
    ):
        checks.append(
            {
                "check": f"{label}_exists",
                "ok": path.is_file(),
                "detail": str(path),
            }
        )

    if not all(item["ok"] for item in checks):
        return emit(
            output_path,
            {
                "ok": False,
                "checks": checks,
                "error": "missing required smoke outputs",
            },
        )

    payload = load_json(result_path)
    notes_text = notes_path.read_text(encoding="utf-8")
    readme_text = readme_path.read_text(encoding="utf-8")

    checks.extend(
        [
            {
                "check": "project_id_present",
                "ok": isinstance(payload.get("project_id"), str) and len(payload["project_id"]) > 0,
                "detail": payload.get("project_id"),
            },
            {
                "check": "workspace_root",
                "ok": payload.get("workspace_root") == ".",
                "detail": payload.get("workspace_root"),
            },
            {
                "check": "service_root",
                "ok": payload.get("service_root") == "./.spiderweb/services",
                "detail": payload.get("service_root"),
            },
            {
                "check": "shared_data_inputs",
                "ok": payload.get("shared_data_inputs") == EXPECTED_SHARED_INPUTS,
                "detail": payload.get("shared_data_inputs"),
            },
            {
                "check": "required_services",
                "ok": payload.get("required_services") == EXPECTED_REQUIRED_SERVICES,
                "detail": payload.get("required_services"),
            },
            {
                "check": "bootstrap_complete",
                "ok": payload.get("bootstrap_complete") is True,
                "detail": payload.get("bootstrap_complete"),
            },
            {
                "check": "shared_data_visible",
                "ok": (shared_data / "world_seed.json").is_file()
                and (shared_data / "items_seed.json").is_file()
                and (shared_data / "puzzle_seed.json").is_file(),
                "detail": str(shared_data),
            },
            {
                "check": "notes_reference_spiderweb",
                "ok": ".spiderweb" in notes_text and "bootstrap" in notes_text.lower(),
                "detail": notes_text[-1000:],
            },
            {
                "check": "readme_mentions_validator",
                "ok": "validate_smoke.py" in readme_text,
                "detail": readme_text[-1000:],
            },
        ]
    )

    return emit(
        output_path,
        {
            "ok": all(item["ok"] for item in checks),
            "checks": checks,
        },
    )


if __name__ == "__main__":
    raise SystemExit(main())
