#!/usr/bin/env python3
"""Restore the official Gradle wrapper without modifying the authored source.

Flutter must be installed and available on PATH (or pass --flutter /path/to/flutter).
This script supports Windows, macOS, and Linux. Temporary generated files live
inside .dart_tool; only the wrapper JAR and genuine .metadata enter this project.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def prepare(flutter_command: str, project: Path) -> None:
    executable = shutil.which(flutter_command)
    if executable is None:
        supplied = Path(flutter_command).expanduser()
        if supplied.is_file():
            executable = str(supplied.resolve())
    if executable is None:
        raise FileNotFoundError(
            "Flutter not found. Install Flutter 3.29.3+ and add flutter/bin to PATH."
        )

    destination = project / "android/gradle/wrapper/gradle-wrapper.jar"
    metadata = project / ".metadata"
    metadata_is_stub = not metadata.exists() or "manual-bootstrap" in metadata.read_text()
    if destination.is_file() and not metadata_is_stub:
        print(f"Gradle wrapper already prepared: {destination}")
        return

    temporary_root = project / ".dart_tool"
    temporary_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="android_template_", dir=temporary_root) as tmp:
        generated = Path(tmp) / "template"
        command = [
            executable, "create", "--no-pub", "--platforms=android",
            "--org=com.martinluk", "--project-name=martin_luk_app", str(generated),
        ]
        subprocess.run(command, check=True, cwd=project)
        generated_jar = generated / "android/gradle/wrapper/gradle-wrapper.jar"
        if not generated_jar.is_file():
            raise FileNotFoundError(
                "Flutter did not generate gradle-wrapper.jar. Run flutter precache --android, "
                "then retry this script."
            )
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(generated_jar, destination)
        if metadata_is_stub:
            shutil.copy2(generated / ".metadata", metadata)
    print(f"Prepared official Gradle wrapper: {destination}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter", default="flutter")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    try:
        prepare(args.flutter, project)
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"Android preparation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
