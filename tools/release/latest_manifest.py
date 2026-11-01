#!/usr/bin/env python3
"""Generate or validate the strict Windows update manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

try:
    from .prepare_release import version_key
except ImportError:  # Direct command-line execution.
    from prepare_release import version_key


SHA_RE = re.compile(r"^[A-Fa-f0-9]{64}$")
CHANNELS = {"stable", "beta", "testing"}
ALLOWED_HOST = "updates.capcmultiservicios.site"
TOP_KEYS = {
    "schemaVersion", "platform", "channel", "versionName", "buildNumber",
    "publishedAt", "mandatory", "minimumSupportedBuild", "releaseNotes", "artifact",
}
ARTIFACT_KEYS = {"url", "sha256", "sizeBytes"}


def _https_capc_url(value: object) -> bool:
    if not isinstance(value, str):
        return False
    parsed = urlparse(value)
    return (
        parsed.scheme == "https"
        and parsed.hostname == ALLOWED_HOST
        and parsed.port in (None, 443)
        and not parsed.username
        and not parsed.password
        and not parsed.fragment
    )


def validate_manifest(data: object) -> dict:
    if not isinstance(data, dict) or set(data) != TOP_KEYS:
        raise ValueError("El manifiesto no tiene exactamente los campos esperados.")
    if data["schemaVersion"] != 1 or data["platform"] != "windows-x64":
        raise ValueError("Esquema o plataforma no compatible.")
    if data["channel"] not in CHANNELS:
        raise ValueError("Canal no compatible.")
    version_key(data["versionName"], data["buildNumber"])
    if not isinstance(data["minimumSupportedBuild"], int) or data["minimumSupportedBuild"] <= 0:
        raise ValueError("minimumSupportedBuild debe ser positivo.")
    if not isinstance(data["mandatory"], bool):
        raise ValueError("mandatory debe ser booleano.")
    if not isinstance(data["releaseNotes"], list) or not data["releaseNotes"]:
        raise ValueError("releaseNotes debe contener al menos una nota.")
    if any(not isinstance(note, str) or not note.strip() for note in data["releaseNotes"]):
        raise ValueError("Las notas no pueden estar vacías.")
    try:
        published = datetime.fromisoformat(data["publishedAt"].replace("Z", "+00:00"))
    except (AttributeError, ValueError) as error:
        raise ValueError("publishedAt debe ser una fecha ISO-8601 válida.") from error
    if published.tzinfo is None:
        raise ValueError("publishedAt debe incluir zona horaria.")
    artifact = data["artifact"]
    if not isinstance(artifact, dict) or set(artifact) != ARTIFACT_KEYS:
        raise ValueError("artifact no tiene exactamente los campos esperados.")
    if not _https_capc_url(artifact["url"]):
        raise ValueError("El artefacto debe usar HTTPS en el dominio CAPC autorizado.")
    if not isinstance(artifact["sizeBytes"], int) or artifact["sizeBytes"] <= 0:
        raise ValueError("sizeBytes debe ser positivo.")
    if not isinstance(artifact["sha256"], str) or not SHA_RE.fullmatch(artifact["sha256"]):
        raise ValueError("sha256 debe contener 64 caracteres hexadecimales.")
    return data


def generate(
    installer: Path,
    output: Path,
    version_name: str,
    build_number: int,
    channel: str,
    mandatory: bool,
    minimum_supported_build: int,
    release_notes: str,
) -> dict:
    version_key(version_name, build_number)
    if channel not in CHANNELS:
        raise ValueError("Canal no compatible.")
    if not installer.is_file() or installer.stat().st_size <= 0:
        raise ValueError("El instalador no existe o está vacío.")
    notes = [line.strip().lstrip("-* ").strip() for line in release_notes.splitlines()]
    notes = [line for line in notes if line]
    relative_name = installer.name
    url = (
        f"https://{ALLOWED_HOST}/windows/{channel}/{version_name}/{relative_name}"
    )
    digest = hashlib.sha256(installer.read_bytes()).hexdigest().upper()
    data = {
        "schemaVersion": 1,
        "platform": "windows-x64",
        "channel": channel,
        "versionName": version_name,
        "buildNumber": build_number,
        "publishedAt": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "mandatory": mandatory,
        "minimumSupportedBuild": minimum_supported_build,
        "releaseNotes": notes,
        "artifact": {"url": url, "sha256": digest, "sizeBytes": installer.stat().st_size},
    }
    validate_manifest(data)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("generate")
    create.add_argument("--installer", required=True, type=Path)
    create.add_argument("--output", required=True, type=Path)
    create.add_argument("--version-name", required=True)
    create.add_argument("--build-number", required=True, type=int)
    create.add_argument("--channel", required=True)
    create.add_argument("--mandatory", choices=("true", "false"), required=True)
    create.add_argument("--minimum-supported-build", type=int, required=True)
    create.add_argument("--release-notes", required=True)
    check = sub.add_parser("validate")
    check.add_argument("--manifest", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "generate":
            generate(
                args.installer, args.output, args.version_name, args.build_number,
                args.channel, args.mandatory == "true", args.minimum_supported_build,
                args.release_notes,
            )
            print(f"Manifiesto generado: {args.output}")
        else:
            validate_manifest(json.loads(args.manifest.read_text(encoding="utf-8")))
            print(f"Manifiesto válido: {args.manifest}")
    except (ValueError, OSError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
