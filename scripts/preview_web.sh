#!/usr/bin/env bash
# Preview only: never downloads/installs Flutter or an Android SDK.
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="auto"
HOST="0.0.0.0"
PORT="8080"
MODE_SELECTED="false"

usage() {
  cat <<'EOF'
Usage: scripts/preview_web.sh [--mock|--serve-built|--build|--dev|--chrome]
                              [--port 8080] [--host 0.0.0.0]
  default       Serve an existing Flutter build; otherwise build with an existing
                Flutter SDK, or serve the HTML mock when Flutter is unavailable.
  --mock        Serve the standalone HTML mock; requires only Python 3.
  --serve-built Serve build/web without downloading or running Flutter.
  --build       Build Flutter Web and serve the complete 390x844 wrapper.
  --dev         Flutter hot reload through web-server; use browser device emulation.
  --chrome      Start Flutter with Chrome; use DevTools for a 390x844 viewport.

The default listener is 0.0.0.0:8080, suitable for remote port forwarding.
Use --host 127.0.0.1 when you want a listener restricted to this machine.
No mode downloads a Flutter SDK or Android SDK. Static modes serve only the
preview assets, never the project root. Ctrl+C stops the server.
EOF
}

while (($#)); do
  case "$1" in
    --mock|--serve-built|--build|--dev|--chrome)
      if [[ "$MODE_SELECTED" == "true" ]]; then
        printf 'Select exactly one preview mode.\n' >&2
        exit 2
      fi
      MODE="${1#--}"
      MODE_SELECTED="true"
      shift ;;
    --port|--host)
      if (($# < 2)); then usage >&2; exit 2; fi
      if [[ "$1" == "--port" ]]; then PORT="$2"; else HOST="$2"; fi
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$PORT" =~ ^[0-9]{1,5}$ ]] || ((10#$PORT < 1 || 10#$PORT > 65535)); then
  printf 'Port must be an integer from 1 to 65535.\n' >&2
  exit 2
fi
# IPv4 addresses or DNS hostnames only; quote every argument passed to a command.
# IPv6 is intentionally unsupported by the bundled IPv4 HTTP server.
if [[ ! "$HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
  printf 'Host must be an IPv4 address or DNS hostname (for example 0.0.0.0).\n' >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'Python 3 is required to validate/serve the preview.\n' >&2
  exit 127
fi

if [[ "$MODE" == "auto" ]]; then
  if [[ -f "$PROJECT_DIR/build/web/index.html" ]]; then
    MODE="serve-built"
  elif command -v flutter >/dev/null 2>&1; then
    MODE="build"
  else
    MODE="mock"
    printf '%s\n' 'Flutter SDK is unavailable; previewing the standalone HTML mock.'
  fi
fi

cd -- "$PROJECT_DIR"
if [[ "$MODE" == "build" || "$MODE" == "dev" || "$MODE" == "chrome" ]]; then
  if ! command -v flutter >/dev/null 2>&1; then
    printf '%s\n' "The --$MODE mode requires an existing Flutter SDK on PATH." >&2
    printf '%s\n' 'Use --mock for the HTML preview, or --serve-built for a compiled build/web directory.' >&2
    exit 127
  fi
  python3 "$PROJECT_DIR/scripts/check_web.py"
  flutter config --enable-web
fi

serve_assets() {
  local source_mode="$1"
  local directory="$2"
  if [[ ! -f "$directory/index.html" ]]; then
    printf 'Missing %s/index.html; the selected preview is unavailable.\n' "$directory" >&2
    if [[ "$source_mode" == "flutter" ]]; then
      printf '%s\n' 'Build with --build, extract the Flutter Web CI artifact into build/web, or use --mock.' >&2
    fi
    exit 1
  fi
  printf 'Preview source: %s (%s)\n' "$source_mode" "$directory"
  exec python3 "$PROJECT_DIR/scripts/preview_server.py" \
    --host "$HOST" --port "$PORT" --mode "$source_mode" --directory "$directory"
}

print_flutter_url() {
  printf '\nFlutter listener: %s:%s\n' "$HOST" "$PORT"
  printf 'On this server: http://127.0.0.1:%s/?preview=mock\n' "$PORT"
  if [[ "$HOST" != "127.0.0.1" && "$HOST" != "localhost" ]]; then
    printf 'From another machine, open the forwarded port URL or http://<server-address>:%s/.\n' "$PORT"
    printf '0.0.0.0 is a listener address; a remote browser\047s 127.0.0.1 points to that browser\047s machine.\n'
  fi
}

case "$MODE" in
  mock)
    serve_assets mock "$PROJECT_DIR/preview"
    ;;
  serve-built)
    serve_assets flutter "$PROJECT_DIR/build/web"
    ;;
  build)
    flutter pub get
    # Bundles CanvasKit on the same origin; no generated service worker/cache.
    flutter build web --release --no-web-resources-cdn --pwa-strategy=none \
      --dart-define=USE_MOCK_DATA=true
    # The Flutter build copies static web files. Fail clearly if it did not.
    if [[ ! -f build/web/phone_preview.html ]]; then
      printf 'Missing build/web/phone_preview.html; Flutter Web build was incomplete.\n' >&2
      exit 1
    fi
    serve_assets flutter "$PROJECT_DIR/build/web"
    ;;
  dev)
    print_flutter_url
    printf 'Set browser DevTools viewport to 390x844.\n'
    exec flutter run -d web-server --web-hostname "$HOST" --web-port "$PORT" \
      --dart-define=USE_MOCK_DATA=true
    ;;
  chrome)
    # Chrome's outer-window size includes browser chrome; DevTools sets exact viewport.
    print_flutter_url
    exec flutter run -d chrome --web-hostname "$HOST" --web-port "$PORT" \
      --web-browser-flag=--window-size=430,940 --dart-define=USE_MOCK_DATA=true
    ;;
esac
