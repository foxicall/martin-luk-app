#!/usr/bin/env python3
"""Optional signed notification; never an inferred original-site upload API."""
import hashlib
import hmac
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class WebhookError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


def https_url(value):
    url = urllib.parse.urlsplit(value)
    if (url.scheme != "https" or not url.hostname or url.username or url.password
            or url.query or url.fragment):
        raise WebhookError("Webhook metadata requires HTTPS without embedded credentials or query")
    return value


def notify(env=None, opener=None, timestamp=None):
    env = os.environ if env is None else env
    endpoint = env.get("ORIGINAL_PWA_WEBHOOK_URL", "")
    secret = env.get("ORIGINAL_PWA_WEBHOOK_SECRET", "")
    if not endpoint or not secret:
        raise WebhookError("Webhook is not configured; no request sent")
    https_url(endpoint)
    commit = env.get("PWA_RELEASE_COMMIT", "")
    repository = env.get("PWA_SOURCE_REPOSITORY", "")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise WebhookError("Invalid release commit; no request sent")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise WebhookError("Invalid source repository; no request sent")
    payload = {"event": "pwa.pages.deployed", "commit": commit, "repository": repository,
               "pages_url": https_url(env.get("PWA_DEPLOYED_URL", "")),
               "run_url": https_url(env.get("PWA_WORKFLOW_RUN_URL", ""))}
    body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    stamp = str(int(time.time()) if timestamp is None else timestamp)
    signature = hmac.new(secret.encode(), stamp.encode() + b"." + body, hashlib.sha256).hexdigest()
    request = urllib.request.Request(endpoint, body, method="POST", headers={
        "Content-Type": "application/json", "X-PWA-Timestamp": stamp,
        "X-PWA-Signature": "sha256=" + signature, "Idempotency-Key": commit})
    opener = opener or urllib.request.build_opener(NoRedirect())
    try:
        with opener.open(request, timeout=15) as response:
            if not 200 <= response.status < 300:
                raise WebhookError(f"Webhook returned HTTP {response.status}")
    except urllib.error.HTTPError as error:
        raise WebhookError(f"Webhook returned HTTP {error.code}; no redirect or retry attempted") from None
    except (OSError, urllib.error.URLError):
        raise WebhookError("Webhook network or TLS failure") from None
    return {"status": "notified", "commit": commit,
            "original_site_deployment_verified": False}


def main():
    try:
        result = notify()
    except (WebhookError, ValueError) as error:
        print(json.dumps({"status": "blocked", "error": str(error)}))
        return 2
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
