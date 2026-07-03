# dust

Monitors the [EarthSense Leicestershire CC public portal](https://portal.earthsense.co.uk/LeicestershireCCPublic)
and opens a GitHub Issue when **Hawcliffe Rd., Mountsorrel** reads elevated NO₂ or PM2.5
compared to the other stations. Runs hourly via GitHub Actions; hourly readings are
archived in `history/` (backfilled to July 2022).

- `ruby monitor.rb run [--dry-run]` — one monitoring pass
- `ruby monitor.rb backfill` — populate `history/` from the API's full history
- `ruby test/monitor_test.rb` — tests (Ruby stdlib only, no gems)

Rules (calibrated against 5 weeks of history — see
`docs/superpowers/specs/2026-07-03-dust-air-quality-monitor-design.md`):
NO₂ alerts at ≥2.5× the other stations' mean and ≥30 µg/m³ above it for 2 consecutive
hours; PM2.5 at ≥1.5× and ≥5 µg/m³ for 2 hours. One alert per episode; re-arms after
6 quiet hours.
