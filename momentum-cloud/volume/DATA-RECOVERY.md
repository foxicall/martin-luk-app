# Daily evidence pipeline — 2026-11-26

Data version: `daily-evidence-20261126`. Synchronized from the active PWA 6.0.21 modules: volume-data, volume-breakout (strategy unchanged), holding-daily and data-quality.

The 2026-11-26 cloud snapshot had 5,184 rows whose missing fields were only close and adjusted close. Real A/AAPL/MSFT Yahoo responses show a missing 2026-11-25 terminal close, while 2026-11-24 is complete. Request variants do not restore the missing source values. Captured response fixtures are in `cloud/fixtures`.

Preserve the latest assessment as insufficient_data. Add a separate, strictly historical, ineligible analysis from the contiguous complete prefix. Only a single terminal close/adjusted-close gap with a verified prior analysis is classified as latest_session_pending. Internal holes, invalid OHLC, inadequate history and stale data remain other missing-data reasons. Counts separately show current completeness, available dated history and unusable data; historical availability is not recovery of the latest fields.

The first sweep still checks both Yahoo hosts and an expanded range. When two hosts confirm the same terminal publication delay and a valid historical analysis exists, skip the redundant second bulk pass for that symbol. Other recoverable gaps retain their forced retry. The next scheduled/manual run always requests fresh data again. `recovery.deferredLatest` records these deferrals; `recovered` never includes them. No schedule, strategy rule, user portfolio or access policy changed.

Run `node --test momentum-cloud/cloud/volume-*.test.mjs`. Native Node test isolation is used in Actions. Tests never use real user holdings or publish synthetic results.
