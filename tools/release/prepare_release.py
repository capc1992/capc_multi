#!/usr/bin/env python3
"""Validate a CAPC release and optionally update pubspec.yaml."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


VERSION_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
PUBSPEC_RE = re.compile(r"(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$")


def version_key(version_name: str, build_number: int) -> tuple[int, int, int, int]:
    match = VERSION_RE.fullmatch(version_name)
    if not match or build_number <= 0:
        raise ValueError("La versión debe ser X.Y.Z y el build_number debe ser positivo.")
    return (*map(int, match.groups()), build_number)


def read_current(pubspec: Path) -> tuple[str, int, str]:
    content = pubspec.read_text(encoding="utf-8")
    match = PUBSPEC_RE.search(content)
    if not match:
        raise ValueError("No se encontró una versión X.Y.Z+N en pubspec.yaml.")
    return match.group(1), int(match.group(2)), content


def prepare(pubspec: Path, version_name: str, build_number: int, write: bool) -> None:
    current_name, current_build, content = read_current(pubspec)
    if version_key(version_name, build_number) <= version_key(current_name, current_build):
        raise ValueError(
            f"La nueva versión {version_name}+{build_number} debe superar "
            f"{current_name}+{current_build}."
        )
    if write:
        updated = PUBSPEC_RE.sub(f"version: {version_name}+{build_number}", content, count=1)
        pubspec.write_text(updated, encoding="utf-8", newline="\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pubspec", type=Path, default=Path("pubspec.yaml"))
    parser.add_argument("--version-name", required=True)
    parser.add_argument("--build-number", required=True, type=int)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    try:
        prepare(args.pubspec, args.version_name, args.build_number, args.write)
    except ValueError as error:
        parser.error(str(error))
    print(f"Versión validada: {args.version_name}+{args.build_number}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
