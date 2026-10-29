#!/usr/bin/env bash
# Linux x86_64 reproducible SDK bootstrap. Requires curl, python3, xz, unzip,
# git, and an existing JDK 17 or 21. No root privileges are needed.
# Preserves HTTP(S)_PROXY and TLS trust; destinations are official SDK hosts.
# Downloaded SDKs may occupy several GB; this directory is outside the source.
set -euo pipefail
project_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
toolchain_dir=${MARTIN_TOOLCHAIN_DIR:-"$project_dir/../toolchains"}
mkdir -p "$toolchain_dir/downloads" "$toolchain_dir/android-sdk" \
  "$toolchain_dir/android-user-home" "$toolchain_dir/gradle-cache"
toolchain_dir=$(CDPATH= cd -- "$toolchain_dir" && pwd)
export ANDROID_HOME="$toolchain_dir/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_USER_HOME="$toolchain_dir/android-user-home"
export GRADLE_USER_HOME="$toolchain_dir/gradle-cache"
export PUB_CACHE="$toolchain_dir/pub-cache"
export XDG_CONFIG_HOME="$toolchain_dir/xdg-config"
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true

for required_command in curl python3 tar unzip java git; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Missing prerequisite: %s\n' "$required_command" >&2
    exit 1
  fi
done

if [[ ! -x "$toolchain_dir/flutter/bin/flutter" ]]; then
  curl --fail --location --retry 3 \
    --output "$toolchain_dir/downloads/releases_linux.json" \
    https://storage.googleapis.com/flutter_infra_release/flutter/releases/releases_linux.json
  python3 - "$toolchain_dir/downloads/releases_linux.json" \
    "$toolchain_dir/downloads/flutter.sha256" <<'PY'
import json
import sys
from pathlib import Path
releases = json.loads(Path(sys.argv[1]).read_text())
release = next(r for r in releases["releases"]
               if r["version"] == "3.29.3" and r["channel"] == "stable")
Path(sys.argv[2]).write_text(release["sha256"])
PY
  curl --fail --location --retry 3 \
    --output "$toolchain_dir/downloads/flutter_linux_3.29.3-stable.tar.xz" \
    https://storage.googleapis.com/flutter_infra_release/flutter/stable/linux/flutter_linux_3.29.3-stable.tar.xz
  python3 - "$toolchain_dir/downloads/flutter_linux_3.29.3-stable.tar.xz" \
    "$toolchain_dir/downloads/flutter.sha256" <<'PY'
import hashlib
import sys
from pathlib import Path
archive, expected = map(Path, sys.argv[1:])
with archive.open("rb") as stream:
    actual = hashlib.file_digest(stream, "sha256").hexdigest()
if actual != expected.read_text().strip():
    raise SystemExit("Flutter SDK checksum mismatch; extraction aborted.")
PY
  tar -xf "$toolchain_dir/downloads/flutter_linux_3.29.3-stable.tar.xz" -C "$toolchain_dir"
fi

if [[ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]]; then
  # Android publishes SHA-1 archive checksums in its official repository XML.
  curl --fail --location --retry 3 \
    --output "$toolchain_dir/downloads/repository2-1.xml" \
    https://dl.google.com/android/repository/repository2-1.xml
  python3 - "$toolchain_dir/downloads/repository2-1.xml" \
    "$toolchain_dir/downloads/android-commandline.sha1" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
root = ET.parse(sys.argv[1]).getroot()
archive_name = "commandlinetools-linux-13114758_latest.zip"
checksums = []
for complete in root.iter("complete"):
    if complete.findtext("url") == archive_name:
        checksums.append(complete.findtext("checksum"))
if not checksums or not checksums[0]:
    raise SystemExit("Pinned Android command-line tools no longer appear in Google's manifest. "
                     "Install official tools manually rather than skipping verification.")
Path(sys.argv[2]).write_text(checksums[0])
PY
  curl --fail --location --retry 3 \
    --output "$toolchain_dir/downloads/commandlinetools-linux-13114758_latest.zip" \
    https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip
  python3 - "$toolchain_dir/downloads/commandlinetools-linux-13114758_latest.zip" \
    "$toolchain_dir/downloads/android-commandline.sha1" <<'PY'
import hashlib
import sys
from pathlib import Path
archive, expected = map(Path, sys.argv[1:])
with archive.open("rb") as stream:
    actual = hashlib.file_digest(stream, "sha1").hexdigest()
if actual != expected.read_text().strip():
    raise SystemExit("Android SDK checksum mismatch; extraction aborted.")
PY
  temporary_tools="$toolchain_dir/downloads/android-tools"
  mkdir -p "$temporary_tools" "$ANDROID_HOME/cmdline-tools"
  unzip -q -o "$toolchain_dir/downloads/commandlinetools-linux-13114758_latest.zip" -d "$temporary_tools"
  mv "$temporary_tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
fi

export PATH="$toolchain_dir/flutter/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
# Java-based SDK/Gradle clients do not consistently honor HTTP(S)_PROXY.
# Propagate the inherited proxy into their supported configuration formats.
# No proxy credentials are printed or copied into the project.
sdkmanager_proxy_args=()
if [[ -n "${HTTPS_PROXY:-${HTTP_PROXY:-}}" ]]; then
  mapfile -t proxy_values < <(python3 - <<'PY'
import os
from urllib.parse import urlparse
proxy = urlparse(os.environ.get("HTTPS_PROXY") or os.environ.get("HTTP_PROXY", ""))
if not proxy.hostname:
    raise SystemExit("Configured proxy is missing a hostname.")
if proxy.username or proxy.password:
    raise SystemExit("Authenticated SDK proxy: use your platform's supported Java configuration.")
print(proxy.hostname)
print(proxy.port or (443 if proxy.scheme == "https" else 80))
PY
  )
  if [[ ${#proxy_values[@]} -ne 2 ]]; then
    echo 'Unable to safely configure Java proxy; SDK installation stopped.' >&2
    exit 1
  fi
  sdkmanager_proxy_args=(--proxy=http --proxy_host="${proxy_values[0]}" --proxy_port="${proxy_values[1]}")
  python3 - "$GRADLE_USER_HOME/gradle.properties" "${proxy_values[0]}" "${proxy_values[1]}" <<'PY'
import sys
from pathlib import Path
target, host, port = sys.argv[1:]
path = Path(target)
existing = path.read_text().splitlines() if path.exists() else []
keys = ("systemProp.http.proxyHost", "systemProp.http.proxyPort",
        "systemProp.https.proxyHost", "systemProp.https.proxyPort")
remaining = [line for line in existing if not line.startswith(tuple(k + "=" for k in keys))]
for protocol in ("http", "https"):
    remaining += [f"systemProp.{protocol}.proxyHost={host}",
                  f"systemProp.{protocol}.proxyPort={port}"]
path.write_text("\n".join(remaining) + "\n")
PY
fi
# Accept standard SDK licenses noninteractively only when run with explicit
# MARTIN_ACCEPT_ANDROID_LICENSES=1. Otherwise sdkmanager prompts for each license.
if [[ "${MARTIN_ACCEPT_ANDROID_LICENSES:-0}" == 1 ]]; then
  set +o pipefail
  yes | sdkmanager "${sdkmanager_proxy_args[@]}" --sdk_root="$ANDROID_HOME" --licenses
  set -o pipefail
else
  sdkmanager "${sdkmanager_proxy_args[@]}" --sdk_root="$ANDROID_HOME" --licenses
fi
sdkmanager "${sdkmanager_proxy_args[@]}" --sdk_root="$ANDROID_HOME" "platform-tools" "platforms;android-36" \
  "build-tools;36.0.0" "ndk;27.0.12077973" "cmake;3.22.1"
flutter config --android-sdk "$ANDROID_HOME"
flutter precache --android
python3 "$project_dir/scripts/prepare_android.py"
cat > "$toolchain_dir/activate.sh" <<EOF
export ANDROID_HOME="$ANDROID_HOME"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_USER_HOME="$ANDROID_USER_HOME"
export GRADLE_USER_HOME="$GRADLE_USER_HOME"
export PUB_CACHE="$PUB_CACHE"
export XDG_CONFIG_HOME="$XDG_CONFIG_HOME"
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
export PATH="$toolchain_dir/flutter/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:\$PATH"
EOF
printf 'SDKs prepared. In this shell run: source %s/activate.sh\n' "$toolchain_dir"
