"""Deployment-handshake tests; these fixtures are not live market evidence."""
from __future__ import annotations

from contextlib import ExitStack
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from pydantic import ValidationError

from backend.api import (
    ApiSettings,
    CapabilitiesResponse,
    RecommendationService,
    ScanCapabilities,
    create_app,
)
from backend.tests.test_api import AsgiClient


class CapabilitiesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def app_for(self, **changes: object):
        settings = ApiSettings(cache_dir=Path(self.temp.name), **changes)
        service = RecommendationService(settings)
        return create_app(service)

    def test_default_full_universe_contract_has_explicit_verification_limit(self) -> None:
        app = self.app_for()
        response = AsgiClient(app).get("/v1/capabilities")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {
            "service": "martin-luk-market-api",
            "api_version": 1,
            "data_mode": "live",
            "markets": ["tw", "us"],
            "scan": {
                "pool_limit": 0,
                "scope": "full_universe",
                "page_size": 60,
                "page_interval_seconds": 60.0,
                "background_jobs": True,
                "continuation": "client_driven",
                "recommendations": "latest_page_only",
            },
            "requires_market_data_verification": True,
        })
        # The exact public shape is also validated through the declared model.
        CapabilitiesResponse.model_validate(response.json())
        self.assertFalse(app.state.background_scans._slots)

    def test_limited_deployment_reports_actual_runtime_configuration(self) -> None:
        app = self.app_for(scan_pool_limit=30, scan_page_size=15,
                           scan_page_interval_seconds=12.5)
        body = AsgiClient(app).get("/v1/capabilities").json()
        self.assertEqual(body["scan"]["pool_limit"], 30)
        self.assertEqual(body["scan"]["scope"], "limited")
        self.assertEqual(body["scan"]["page_size"], 15)
        self.assertEqual(body["scan"]["page_interval_seconds"], 12.5)
        self.assertTrue(body["requires_market_data_verification"])

    def test_unavailable_providers_do_not_block_capabilities_or_health(self) -> None:
        app = self.app_for()
        service = app.state.recommendation_service
        quote_service = app.state.quote_service
        client = AsgiClient(app)
        # Any accidental price, calendar, directory, cache or worker operation
        # fails immediately. Neither lightweight endpoint should invoke one.
        with ExitStack() as stack:
            guards = [
                stack.enter_context(patch.object(owner, attribute,
                    side_effect=AssertionError("provider must not be touched")))
                for owner, attribute in (
                    (service, "get_candidates"),
                    (service, "background_cached_response"),
                    (service, "_scan_live"),
                    (service.calendar, "context"),
                    (quote_service, "get_quotes"),
                    (quote_service.calendar, "context"),
                )
            ]
            guards.extend([
                stack.enter_context(patch("backend.api.UniverseProvider",
                    side_effect=AssertionError("directory unavailable"))),
                stack.enter_context(patch("backend.api.MarketDataLoader",
                    side_effect=AssertionError("prices unavailable"))),
            ])
            capabilities = client.get("/v1/capabilities")
            health = client.get("/health")
            self.assertEqual(capabilities.status_code, 200)
            self.assertTrue(capabilities.json()["requires_market_data_verification"])
            self.assertEqual(health.status_code, 200)
            self.assertFalse(health.json()["provider_verified"])
            for guard in guards:
                guard.assert_not_called()
        self.assertFalse(app.state.background_scans._slots)
        self.assertEqual(list(Path(self.temp.name).iterdir()), [])

    def test_schema_rejects_contradictory_scope_and_nonfinite_configuration(self) -> None:
        for changes in ({"pool_limit": 30, "scope": "full_universe"},
                        {"pool_limit": 0, "scope": "limited"},
                        {"page_interval_seconds": float("nan")}):
            with self.subTest(changes=changes), self.assertRaises(ValidationError):
                ScanCapabilities(**{
                    "pool_limit": 0,
                    "scope": "full_universe",
                    "page_size": 60,
                    "page_interval_seconds": 60.0,
                    **changes,
                })


if __name__ == "__main__":
    unittest.main()
