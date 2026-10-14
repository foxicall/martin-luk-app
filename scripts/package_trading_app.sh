#!/usr/bin/env bash
# One command: source validation, ZIP, SHA256, Base64 and archive integrity.
# --print-base64 and --print-html are also supported by the shared exporter.
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MARTIN_EXPORT_ZIP_PATH=/workspace/martin_luk_trading_app.zip \
  bash "$PROJECT_DIR/scripts/export_upload.sh" "$@"
