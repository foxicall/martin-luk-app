import hashlib
import hmac
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import MagicMock
import urllib.error

SPEC = importlib.util.spec_from_file_location("pwa_webhook", Path(__file__).parents[1] / "pwa_webhook.py")
webhook = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(webhook)


class WebhookTests(unittest.TestCase):
    def setUp(self):
        self.env = {
            "ORIGINAL_PWA_WEBHOOK_URL": "https://example.com/webhook",
            "ORIGINAL_PWA_WEBHOOK_SECRET": "test fixture secret",
            "PWA_RELEASE_COMMIT": "a" * 40,
            "PWA_SOURCE_REPOSITORY": "foxicall/martin-luk-app",
            "PWA_DEPLOYED_URL": "https://foxicall.github.io/martin-luk-app/",
            "PWA_WORKFLOW_RUN_URL": "https://github.com/foxicall/martin-luk-app/actions/runs/1",
        }
        self.opener = MagicMock()
        self.opener.open.return_value.__enter__.return_value.status = 204

    def test_missing_configuration_never_sends_a_request(self):
        with self.assertRaisesRegex(webhook.WebhookError, "not configured"):
            webhook.notify({}, self.opener)
        self.opener.open.assert_not_called()

    def test_signed_timestamped_payload_and_idempotency_key(self):
        result = webhook.notify(self.env, self.opener, timestamp=123)
        request = self.opener.open.call_args.args[0]
        expected = hmac.new(self.env["ORIGINAL_PWA_WEBHOOK_SECRET"].encode(),
                            b"123." + request.data, hashlib.sha256).hexdigest()
        headers = {k.lower(): v for k, v in request.header_items()}
        self.assertEqual(headers["x-pwa-signature"], "sha256=" + expected)
        self.assertEqual(headers["idempotency-key"], "a" * 40)
        self.assertNotIn(self.env["ORIGINAL_PWA_WEBHOOK_SECRET"], request.data.decode())
        self.assertEqual(json.loads(request.data)["event"], "pwa.pages.deployed")
        self.assertEqual(result["status"], "notified")
        self.assertFalse(result["original_site_deployment_verified"])

    def test_insecure_or_credential_bearing_urls_are_rejected_before_send(self):
        for url in ("http://example.com/hook", "https://user:pass@example.com/", "https://example.com/?token=x"):
            with self.assertRaises(webhook.WebhookError):
                webhook.notify({**self.env, "ORIGINAL_PWA_WEBHOOK_URL": url}, self.opener)
        self.opener.open.assert_not_called()

    def test_http_failure_has_no_retry_and_redirects_are_disabled(self):
        self.opener.open.side_effect = urllib.error.HTTPError("", 302, "redirect", {}, None)
        with self.assertRaisesRegex(webhook.WebhookError, "HTTP 302"):
            webhook.notify(self.env, self.opener)
        self.opener.open.assert_called_once()
        self.assertIsNone(webhook.NoRedirect().redirect_request(None, None, 302, "", {}, "https://elsewhere.test"))


if __name__ == "__main__":
    unittest.main()
