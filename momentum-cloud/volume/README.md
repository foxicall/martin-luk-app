# Volume Breakout cloud scanner

The existing scheduled workflow now invokes `cloud/volume-runner.mjs`. It uses the
same six source modules as the Sites PWA 6.0.5 (Volume Breakout 1.0.0), including
adjusted completed daily bars, the 30-day base, 1.5 × previous 20-day volume,
5% chase ceiling, fixed 7% stop and 21EMA exit. No browser or account data is read.

The existing schedule remains Monday–Friday 07:17 and 22:17 UTC. GitHub may delay
scheduled runs. A push to these files also runs the workflow. Manual runs use the
existing workflow_dispatch button. Closing the PWA does not affect the runner.

Only the dedicated `momentum-scan-data` branch receives public results:
`volume-latest.json`, `volume-universe.json`, `volume-runs/<run>/...`.
Version 2 manifests reject legacy Hybrid results. Failed requests, insufficient
history, complete processing, and complete exchange coverage are distinct.
Partial directories reuse known identities with explicit warnings. Checkpoints
publish about once a minute. Resume is restricted to the same code, universe
and UTC date; failed rows retry. Three fully failed batches pause the run.
The 160-minute processing budget leaves time to persist before CI's timeout.
No force pushes are used. The previous run remains readable during polling.

When updating shared strategy modules, copy them from the Sites repository and
run `node --test momentum-cloud/cloud/volume-runner.test.mjs` before publishing.
