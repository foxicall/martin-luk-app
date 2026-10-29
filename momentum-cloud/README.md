# PWA cloud ranking data

The PWA's Hybrid 1.3.0 client needs 20- and 60-session **stock close returns**, strategy provenance and the full market directory denominator. The previous cloud strategy emitted benchmark-relative 5/20-session values without a 60-session return, and compact serialization omitted the strategy version. Those rows cannot be promoted to the new ranking method.

This change synchronizes the cloud strategy/provider with the PWA, retains strategy version, return method and checks in compact daily summaries, and publishes per-market ranking readiness. The provider drops only provable trailing zero-volume placeholders after the last quoted session; it does not discard ordinary zero-volume history. Original directory membership and missing stocks remain in the denominator.

Only a full, unique, same-date market with all required returns can qualify its top 5%/3% scanners. A separate same-date sample reference can be shown when history is missing; it never qualifies a scanner. Corporate/order-flow evidence stays missing and daily summaries cannot create entries. Existing positions, account data, schedules and Android code are untouched. After merge, the existing main-push workflow runs a new market scan; the old snapshot cannot be repaired by relabeling its fields.

Validation: `node --test --test-isolation=none momentum-cloud/tests/*.test.mjs` (12 tests). The PR checks are read-only and use synthetic market data plus local temporary Git repositories; they do not run a live scan or publish generated data. The existing scheduled scan workflow remains unchanged.

Taiwan directory outage recovery: ISIN requests now time out after 10 seconds per
source and fall back once to the official TWSE/TPEx company-data APIs. JSON shape,
record count, unique codes, ordinary-share counts and a consistent source date
(no future dates, maximum 7 calendar days) are checked. Dates and failed primary
attempts remain in the manifest. Company-code classification lacks per-security
CFI verification, so `rankEligible: false` preserves the fetched denominator for
sample RS without granting whole-market top-3%/top-5% qualification. Both-source
failure still fails the run; no synthetic prices or narrowed denominator are used.

Validation: `node --test --test-isolation=none momentum-cloud/tests/*.test.mjs`
(17 passing). On 2026-10-29 the live fallback returned 1,088 TWSE and 896 TPEx
companies, dated 2026-10-28; this validates directory retrieval only, not complete
market price coverage. Production schedules use main and require this PR to merge.

Cloud transport follow-up: production run 40812994066 reached the official TPEx
backup but its response body terminated / timed out on two attempts. The cloud
runner now gives the official company-feed download 30 seconds (primary remains
10 seconds) and retries that backup at most once for a timeout, interrupted body
or HTTP 502/503/504/522. Schema failures and access denials are not retried. The
maximum Taiwan directory wait is about 70 seconds, bounded independently for each
parallel source. A separate read-only GitHub PR workflow checks actual TWSE/TPEx
connectivity without scanning stocks or publishing data. 19 unit tests pass.
