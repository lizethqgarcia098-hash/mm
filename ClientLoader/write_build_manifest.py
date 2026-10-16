#!/usr/bin/env python3
"""Write a source- and toolchain-specific manifest for the integrated iOS loader."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PATCH_ROOT = "3105/Patches/Minecraft/Application/com.mojang.minecraftpe/Documents/ClientLoader"
PATCH_SCRIPT_PAIRS = (
    (
        "ClientLoader/scripts/client.js",
        f"{PATCH_ROOT}/scripts/client.js",
    ),
    (
        "ClientLoader/scripts/esp_test.js",
        f"{PATCH_ROOT}/scripts/esp_test.js",
    ),
    (
        "ClientLoader/scripts/snapshot_contract_probe.js",
        f"{PATCH_ROOT}/scripts/snapshot_contract_probe.js",
    ),
)
PATCH_ENTITY_REGISTRY = f"{PATCH_ROOT}/entity_registry.json"

SOURCE_PATHS = (
    ".github/workflows/build-ios-client-loader.yml",
    "ClientLoader/build.sh",
    "ClientLoader/ClientLoader.m",
    "ClientLoader/providers/CLCameraProvider.h",
    "ClientLoader/providers/CLDiagnostics.h",
    "ClientLoader/providers/CLSnapshotBridge.h",
    "ClientLoader/providers/CLEntityProvider.h",
    "ClientLoader/providers/CLEntityTypeRegistry.h",
    "ClientLoader/providers/CLESPOverlay.h",
    "ClientLoader/providers/CLProjection.h",
    "ClientLoader/providers/CLSnapshotBridge.m",
    "ClientLoader/providers/CLProjection.c",
    "ClientLoader/providers/CLEntityProvider.m",
    "ClientLoader/providers/CLEntityTypeRegistry.m",
    "ClientLoader/providers/CLCameraProvider.m",
    "ClientLoader/providers/CLESPOverlay.m",
    "ClientLoader/providers/CLDiagnostics.m",
    *(path for pair in PATCH_SCRIPT_PAIRS for path in pair),
    PATCH_ENTITY_REGISTRY,
    "Minecraft-iOS-MITM/core/include/CLSnapshot.h",
    "Minecraft-iOS-MITM/core/src/CLSnapshot.c",
    "ClientLoader/write_build_manifest.py",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest(
    repository_root: Path,
    source_commit: str,
    xcode_version: str,
    iphoneos_sdk_version: str,
    runner_os: str,
    built_at_utc: str | None = None,
) -> dict[str, Any]:
    missing = [
        source for source in SOURCE_PATHS
        if not (repository_root / source).is_file()
    ]
    loader = repository_root / "ClientLoader/ClientLoader.dylib"
    if not loader.is_file():
        missing.append("ClientLoader/ClientLoader.dylib")
    if missing:
        raise FileNotFoundError(
            "Cannot create build manifest; missing input(s): " + ", ".join(missing)
        )

    for source, patch in PATCH_SCRIPT_PAIRS:
        if (repository_root / source).read_bytes() != (repository_root / patch).read_bytes():
            raise ValueError(f"Loader script differs from the 3105 patch payload: {source}")

    return {
        "schema_version": 1,
        "build_status": "BUILT",
        "built_at_utc": built_at_utc or datetime.now(timezone.utc).isoformat(),
        "source_commit": source_commit,
        "target": {
            "platform": "iOS",
            "architecture": "arm64",
            "minimum_ios_version": "15.0",
            "minecraft_executable_included": False,
        },
        "toolchain": {
            "runner_os": runner_os,
            "xcode": xcode_version,
            "iphoneos_sdk": iphoneos_sdk_version,
        },
        "source_files": {
            source: sha256_file(repository_root / source)
            for source in SOURCE_PATHS
        },
        "loader_sha256": sha256_file(loader),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("ClientLoader/BuildManifest.json"),
    )
    args = parser.parse_args()

    xcode = subprocess.check_output(["xcodebuild", "-version"], text=True).strip()
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], text=True
    ).strip()
    manifest = build_manifest(
        args.repository_root.resolve(),
        os.environ["GITHUB_SHA"],
        xcode,
        sdk,
        platform.platform(),
    )
    output = args.output
    if not output.is_absolute():
        output = args.repository_root / output
    output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
