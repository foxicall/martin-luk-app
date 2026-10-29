#!/usr/bin/env python3
"""Audit, package, publish through a configured adapter, and verify a PWA.

No hosting provider or upload API is inferred from a public site URL.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "deployment/pwa-target.json"
ASSET = "assets/assets/data/stock_industries.json"
RELEASE = "pwa-release.json"
CRITICAL = ("index.html", "main.dart.js", "flutter_bootstrap.js",
            "flutter_service_worker.js", ASSET)


class ReleaseError(Exception):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def target_url(value, base_href="/"):
    url = urllib.parse.urlsplit(value)
    if (not re.fullmatch(r"/(?:[A-Za-z0-9_.-]+/)*", base_href) or
            any(part in (".", "..") for part in base_href.split("/"))):
        raise ReleaseError("Invalid deployment base href")
    if (url.scheme != "https" or not url.hostname or url.username or
            url.password or url.query or url.fragment or (url.path or "/") != base_href):
        raise ReleaseError("Target must be HTTPS, without credentials or query, and match base href")
    return value.rstrip("/") + "/"


def settings(path):
    config = json.loads(Path(path).read_text())
    config["target_url"] = target_url(config["target_url"], config.get("base_href", "/"))
    return config


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def audit(config, network=False):
    refs = []
    for name in ("render.yaml", "Dockerfile", "vercel.json", "netlify.toml",
                 "firebase.json", "wrangler.toml", "web/CNAME", "deployment/pwa-target.json",
                 "deployment/pages-target.json"):
        if (ROOT / name).is_file():
            refs.append(name)
    for directory in (ROOT / ".github/workflows", ROOT / "web"):
        for path in sorted(directory.rglob("*")):
            if path.is_file() and path.suffix in (".yml", ".yaml", ".json"):
                refs.append(str(path.relative_to(ROOT)))
    result = {
        "target_url": config["target_url"],
        "publisher_configured": bool(config.get("publisher")),
        "deployment_status": "not_attempted",
        "configuration_files": refs,
        "web_cname_exists": (ROOT / "web/CNAME").is_file(),
        "github_secrets": "not_inspected; absence cannot be inferred",
    }
    if network:
        host = urllib.parse.urlsplit(config["target_url"]).hostname
        try:
            result["dns_addresses"] = sorted({r[4][0] for r in socket.getaddrinfo(host, 443)})
        except OSError as error:
            result["dns_error"] = type(error).__name__
        try:
            request = urllib.request.Request(config["target_url"], method="HEAD")
            with urllib.request.urlopen(request, timeout=20) as response:
                result["http_status"] = response.status
        except urllib.error.HTTPError as error:
            result["http_status"] = error.code
        except (OSError, urllib.error.URLError) as error:
            result["http_error"] = type(error).__name__
        result["hosting_provider"] = "not established by DNS or HTTP status"
    return result


def package(web_dir, output, config, revision, source_asset):
    web_dir, output = Path(web_dir).resolve(), Path(output).resolve()
    if output == web_dir or web_dir in output.parents:
        raise ReleaseError("Release output must be outside the Web build directory")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ReleaseError("Invalid source commit")
    for name in CRITICAL:
        if not (web_dir / name).is_file():
            raise ReleaseError(f"Missing Web artifact: {name}")
    base_href = config.get("base_href", "/")
    target_url(config["target_url"], base_href)
    pattern = r'<base\s+href=[\"\']' + re.escape(base_href) + r'[\"\']'
    if not re.search(pattern, (web_dir / "index.html").read_text()):
        raise ReleaseError(f"The deployment target requires base href {base_href!r}")
    source = Path(source_asset).read_bytes()
    if (web_dir / ASSET).read_bytes() != source:
        raise ReleaseError("Bundled classification differs from source")
    data = json.loads(source)
    if not isinstance(data, dict) or len(data) != 7091:
        raise ReleaseError("Expected 7,091 industry records")
    asset_manifest = json.loads((web_dir / "assets/AssetManifest.json").read_text())
    if "assets/data/stock_industries.json" not in asset_manifest:
        raise ReleaseError("Classification missing from AssetManifest")
    if ASSET not in (web_dir / "flutter_service_worker.js").read_text():
        raise ReleaseError("Classification missing from Service Worker")
    files = {}
    for path in sorted(web_dir.rglob("*")):
        if path.is_symlink():
            raise ReleaseError("Web artifacts cannot contain symlinks")
        if path.is_file():
            name = path.relative_to(web_dir).as_posix()
            if name != RELEASE:
                files[name] = digest(path.read_bytes())
    manifest = {"schema": 1, "commit": revision, "target_url": config["target_url"],
                "base_href": base_href, "industry_count": len(data), "files": files}
    payload = (json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / ("martin-luk-pwa-root.zip" if base_href == "/" else "martin-luk-pwa-pages.zip")
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for name in sorted([*files, RELEASE]):
            info = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            bundle.writestr(info, payload if name == RELEASE else (web_dir / name).read_bytes())
    write_json(output / RELEASE, manifest)
    (output / "SHA256SUMS").write_text(f"{digest(archive.read_bytes())}  {archive.name}\n")
    validate_archive(archive, manifest)
    return {"status": "packaged", "archive": str(archive), "commit": revision,
            "sha256": digest(archive.read_bytes()), "deployed": False}


def validate_archive(archive, manifest):
    with zipfile.ZipFile(archive) as bundle:
        names = bundle.namelist()
        if len(set(names)) != len(names) or set(names) != {*manifest["files"], RELEASE}:
            raise ReleaseError("Archive inventory differs from release manifest")
        if json.loads(bundle.read(RELEASE)) != manifest:
            raise ReleaseError("Archive release manifest differs from sidecar")
        for name, checksum in manifest["files"].items():
            if name.startswith("/") or "\\" in name or ".." in Path(name).parts:
                raise ReleaseError("Unsafe archive member")
            if digest(bundle.read(name)) != checksum:
                raise ReleaseError(f"Archive hash mismatch: {name}")


def fetch(url):
    try:
        request = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
        with urllib.request.urlopen(request, timeout=30) as response:
            if urllib.parse.urlsplit(response.url).netloc != urllib.parse.urlsplit(url).netloc:
                raise ReleaseError("Verification redirected to a different origin")
            return response.read()
    except urllib.error.HTTPError as error:
        raise ReleaseError(f"Live verification blocked by HTTP {error.code}") from None
    except (OSError, urllib.error.URLError):
        raise ReleaseError("Live verification failed: network or TLS error") from None


def verify(config, manifest):
    target = config["target_url"]
    if manifest["target_url"] != target:
        raise ReleaseError("Release target does not match deployment configuration")
    try:
        live = json.loads(fetch(target + RELEASE + "?release=" + manifest["commit"]))
    except (ValueError, UnicodeError):
        raise ReleaseError("Live release manifest is not JSON") from None
    if live != manifest:
        raise ReleaseError("Live release manifest does not match this release")
    for name in CRITICAL:
        payload = fetch(target + urllib.parse.quote(name, safe="/") + "?release=" + manifest["commit"])
        if digest(payload) != manifest["files"][name]:
            raise ReleaseError(f"Live hash mismatch: {name}")
    return {"status": "verified", "target_url": target, "commit": manifest["commit"]}


def deploy(config, archive, manifest):
    command = config.get("publisher")
    if not isinstance(command, list) or not command or any(not isinstance(v, str) or not v for v in command):
        raise ReleaseError("DEPLOY_BLOCKED: no confirmed publisher configured for this site")
    if config["target_url"] != manifest["target_url"]:
        raise ReleaseError("Release target mismatch; refusing publication")
    validate_archive(archive, manifest)
    env = {**os.environ, "PWA_RELEASE_ARCHIVE": str(Path(archive).resolve()),
           "PWA_RELEASE_MANIFEST": str(Path(archive).resolve().parent / RELEASE),
           "PWA_TARGET_URL": config["target_url"], "PWA_RELEASE_COMMIT": manifest["commit"]}
    # Explicit trusted adapter; no shell, inferred API, or credential discovery.
    try:
        result = subprocess.run(command, env=env, capture_output=True, timeout=300)
    except subprocess.TimeoutExpired:
        raise ReleaseError("Publisher timed out after 300 seconds") from None
    except OSError:
        raise ReleaseError("Configured publisher could not start") from None
    if result.returncode:
        raise ReleaseError(f"Publisher failed with exit code {result.returncode}; no verified deployment")
    return verify(config, manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("audit", "package", "deploy", "verify"))
    parser.add_argument("--config", type=Path, default=CONFIG)
    parser.add_argument("--web-dir", type=Path, default=ROOT / "build/pwa-root")
    parser.add_argument("--out-dir", type=Path, default=ROOT / "build/pwa-release")
    parser.add_argument("--network", action="store_true", help="Audit public DNS and HTTP; no credentials")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        config = settings(args.config)
        if args.action == "audit":
            result = audit(config, args.network)
        elif args.action == "package":
            revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
            result = package(args.web_dir, args.out_dir, config, revision, ROOT / "assets/data/stock_industries.json")
        else:
            manifest = json.loads((args.out_dir / RELEASE).read_text())
            archive = ("martin-luk-pwa-root.zip" if config.get("base_href", "/") == "/"
                       else "martin-luk-pwa-pages.zip")
            result = (deploy(config, args.out_dir / archive, manifest)
                      if args.action == "deploy" else verify(config, manifest))
    except (ReleaseError, OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        result = {"status": "blocked", "deployed": False, "error": str(error)}
        if args.report:
            write_json(args.report, result)
        print(json.dumps(result, ensure_ascii=False))
        return 2
    if args.report:
        write_json(args.report, result)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
