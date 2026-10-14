#!/usr/bin/env bash
# Validate and bundle both deliverables without Flutter, Android SDK or network.
# Run from any directory: bash /workspace/martin_luk_app/scripts/package_deliverable.sh
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_ZIP=/workspace/martin_luk_app_deliverable.zip

for required_command in python3 zip sha256sum ls; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$required_command" >&2
    exit 1
  fi
done

cd -- "$PROJECT_DIR"
python3 scripts/verify_deliverable.py --write-manifest

# Keep exclusions in sync with verify_deliverable.py. Include .github workflows,
# source tests, font/license files and placeholder key.properties.example.
EXCLUDE_PATTERNS=()
for excluded_directory in \
  .git build .dart_tool .gradle .cache cache data_cache __pycache__ .venv venv \
  node_modules .pytest_cache .mypy_cache .ruff_cache .idea .vscode .toolchains \
  toolchains .aws .codex .agents logs; do
  EXCLUDE_PATTERNS+=("$excluded_directory/" "$excluded_directory/*" \
    "*/$excluded_directory/" "*/$excluded_directory/*")
done
EXCLUDE_PATTERNS+=(
  '*.pyc' '*.pyo' '*.log' '*.zip' '*.b64' '*.sha256' '*.jks' '*.keystore' '*.pem' '*.key'
  '.DS_Store' '*/.DS_Store' 'Thumbs.db' '*/Thumbs.db'
  'local.properties' '*/local.properties' 'key.properties' '*/key.properties'
  '.env' '*/.env' '.env.local' '*/.env.local' '.env.production' '*/.env.production'
  '.env.*.local' '*/.env.*.local'
)

# Remove only the previous generated output; zip updates can retain stale entries.
rm -f -- "$OUTPUT_ZIP" "$OUTPUT_ZIP.sha256"
zip -r /workspace/martin_luk_app_deliverable.zip . -x "${EXCLUDE_PATTERNS[@]}"
python3 scripts/verify_deliverable.py --archive "$OUTPUT_ZIP"
ls -lh /workspace/martin_luk_app_deliverable.zip
sha256sum "$OUTPUT_ZIP" | tee "$OUTPUT_ZIP.sha256"
printf '\nDownload file: %s\n' "$OUTPUT_ZIP"
printf 'Extract, then open preview/index.html in a browser for the offline preview.\n'
