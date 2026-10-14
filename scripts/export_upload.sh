#!/usr/bin/env bash
# Build the upload bundle and a copyable Base64 export without an SDK or network.
# Usage: bash scripts/export_upload.sh [--print-base64 | --print-html | --help]
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_ZIP="${MARTIN_EXPORT_ZIP_PATH:-/workspace/martin_luk_app_upload.zip}"
PRINT_MODE=none

usage() {
  printf 'Output ZIP: %s\n' "$OUTPUT_ZIP"
  cat <<'HELP'
Usage: bash scripts/export_upload.sh [--print-base64 | --print-html | --help]

Default: validate sources, create the output ZIP shown above,
         verify its manifest/CRC, then write .zip.b64 and .zip.sha256.
--print-base64  Also print the complete Base64 between BEGIN/END markers.
               Copy only the Base64 lines; terminal output may be truncated.
--print-html    Print standalone_preview.html only; do not build a ZIP.
--help          Show this help.
HELP
}

if (( $# > 1 )); then usage >&2; exit 2; fi
case "${1:-}" in
  '') ;;
  --print-base64) PRINT_MODE=base64 ;;
  --print-html) PRINT_MODE=html ;;
  --help|-h) usage; exit 0 ;;
  *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  printf 'Missing required command: python3\n' >&2
  exit 1
fi
cd -- "$PROJECT_DIR"
if [[ "$PRINT_MODE" == html ]]; then
  python3 -c 'from pathlib import Path; import sys; sys.stdout.buffer.write(Path("standalone_preview.html").read_bytes())'
  exit 0
fi
for required_command in zip ls; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$required_command" >&2
    exit 1
  fi
done

python3 scripts/verify_deliverable.py --write-manifest

# Match the manifest verifier's exclusions. Avoid *.git* or *build*: those would
# also remove .github/workflows/build_apk.yml and scripts/build_android.sh.
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

# zip updates retain old entries, so remove only this task's generated outputs.
rm -f -- "$OUTPUT_ZIP" "$OUTPUT_ZIP.b64" "$OUTPUT_ZIP.sha256"
zip -r -q "$OUTPUT_ZIP" . -x "${EXCLUDE_PATTERNS[@]}"
python3 scripts/verify_deliverable.py --archive "$OUTPUT_ZIP"

# Standard-library Base64 wraps at 76 ASCII characters per line. The checksum
# records just the basename, allowing sha256sum -c after moving the ZIP locally.
python3 - "$OUTPUT_ZIP" <<'PY'
import base64
import hashlib
from pathlib import Path
import sys

archive = Path(sys.argv[1])
encoded = Path(str(archive) + ".b64")
with archive.open("rb") as source, encoded.open("wb") as target:
    base64.encode(source, target)
digest = hashlib.sha256()
with archive.open("rb") as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
checksum = f"{digest.hexdigest()}  {archive.name}\n"
Path(str(archive) + ".sha256").write_text(checksum, encoding="ascii")
print(checksum, end="")
PY

ls -lh "$OUTPUT_ZIP" "$OUTPUT_ZIP.b64" "$OUTPUT_ZIP.sha256"
printf '\nZIP: %s\nBase64: %s.b64\nSHA256: %s.sha256\n' "$OUTPUT_ZIP" "$OUTPUT_ZIP" "$OUTPUT_ZIP"
printf 'Recover locally: python3 scripts/recover_upload.py INPUT.b64 --output %s --sha256 EXPECTED_HEX\n' "${OUTPUT_ZIP##*/}"
if [[ "$PRINT_MODE" == base64 ]]; then
  printf '\n-----BEGIN MARTIN LUK ZIP BASE64-----\n'
  python3 - "$OUTPUT_ZIP.b64" <<'PY'
from pathlib import Path
import sys
sys.stdout.buffer.write(Path(sys.argv[1]).read_bytes())
PY
  printf '\n-----END MARTIN LUK ZIP BASE64-----\n'
fi
