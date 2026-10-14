#!/usr/bin/env bash
# Install Flutter and Android SDK first, then run from any working directory.
# Example: ./scripts/build_android.sh --split-per-abi
set -euo pipefail
project_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_dir"

if ! command -v flutter >/dev/null 2>&1; then
  echo 'Flutter not found. See scripts/install_toolchains.sh or install Flutter 3.29.3+.' >&2
  exit 1
fi
python3 scripts/prepare_android.py
flutter pub get
flutter analyze
flutter test
flutter build apk --release --dart-define=USE_MOCK_DATA=true "$@"
printf 'APK output directory: %s/build/app/outputs/flutter-apk/\n' "$project_dir"
