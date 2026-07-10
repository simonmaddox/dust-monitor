# CLAUDE.md

Air quality monitor for Hawcliffe Rd., Mountsorrel. One Ruby file (`monitor.rb`),
daily GitHub Actions digest, CSV archive in `history/`. The design authority is
`docs/superpowers/specs/2026-07-03-dust-air-quality-monitor-design.md` (spec +
dated amendments); read it before changing behaviour.

## Commands

```
ruby test/monitor_test.rb       # test suite (Minitest, no gems) — run before every commit
ruby -c monitor.rb              # syntax check
ruby monitor.rb run --dry-run   # live run against the real API; writes archive but NOT state/stations/notifications
ruby monitor.rb run             # full pass: fetch, evaluate, notify (opens GitHub issues!), save state
ruby monitor.rb backfill        # repopulate history/ from the API (idempotent, resumable, ~5 min)
ruby monitor.rb migrate-columns # one-off header migration (already done)
```

## Hard constraints

- **Ruby 2.6 compatible.** Simon's Mac runs system Ruby 2.6.10. No `filter_map`,
  no endless methods (`def x = y`), no `Hash#except`, no pattern matching. CI uses
  a newer Ruby, so incompatibilities pass there and fail locally — test locally.
- **Stdlib only.** No gems, no Gemfile. This is deliberate.
- **No secrets.** The repo is public. The EarthSense "credential" is the public
  portal slug used as username+password — that's by design, not a leak. The
  workflow uses only the Actions-provided `GITHUB_TOKEN`.
- **TDD.** Every behaviour change: failing test in `test/monitor_test.rb` first.

## Git workflow gotcha

The GitHub Actions workflow **commits to main daily** (~06:15 UTC cron, plus manual
dispatches): `state.json`, `stations.json`, `history/`. Before pushing, always
`git pull --ff-only origin main` (use `-c credential.helper='!gh auth git-credential'`
— plain git has no GitHub credentials here; `gh` is authenticated). Local dry-runs
also dirty `history/` — `git checkout -- history/` before pulling is usually right;
the self-healing fetch window (42h) re-covers anything discarded.

## EarthSense API notes (hard-won)

- Auth: `GET service.earthsense.co.uk/auth/api/authuser?auth=base64(slug:slug)`
  where slug = `LeicestershireCCPublic`. Token lasts ~1 week; we fetch fresh each run.
- **HTTP 240 means "no data for period"**, not an error (handled in `get_json`).
- Station list: `/zephyr/api/v2/getzephyrs`, keep `type == 0 && alias`.
- Data timestamps are hour labels in UTC; only completed hours are archived.
- Station numbers are unstable identity — column names use slugs **pinned in
  `stations.json`**; never regenerate slugs from aliases for existing stations.

## Data rules

- `history/` stores **raw** API values, including garbage. Filtering (negative,
  NO₂ > 1000, PM2.5 > 500) happens at evaluation time only. Never "clean" the CSVs.
- Known quirks: Hawcliffe PM2.5 is garbage 2025-06-21T06Z – 2025-07-09T15Z; the
  `no` channel is ~all zeros after 2023; `o3` is unreliable during NO₂ spikes
  (cross-interference). See README "Data format".
- Alerting covers **PM2.5 only**: `RULES.keys` drives every digest section
  (episodes, limits, data problems, daily-means table). NO₂ alerting was removed
  2026-07-10 on CBC Environmental Health's advice (the monitor sits inside the
  LCC highways depot car park; its siting doesn't meet NO₂ deployment guidelines)
  — NO₂ is still archived as a combustion tracer for analysis, and `LIMITS`
  keeps a dormant `no2` entry (documented values + machinery tests). `LIMITS`
  holds the currently-in-force EU values — the stricter 2030 values are in a
  comment above it and in the README, and the dormant `:daily` machinery in
  `Limits.check` is tested and ready for that switchover.

## Context that shapes decisions

- The monitored sensor is Charnwood BC's Zephyr (LAQM site CM5) inside the LCC
  depot on the Mountsorrel Quarry (Tarmac) boundary. Simon lives near the
  quarry's "Stn 11" locality and receives the quarry's monthly DustScanAQ
  compliance reports.
- `reports/` contains council-facing evidence documents. **Tone rule from Simon:
  factual, no fault attribution — never imply anyone failed to do their job.**
  These documents are shared with Leicestershire CC's environmental health team;
  don't edit them without being asked.
- Sensor values are indicative, not reference-grade; keep that caveat in any
  analysis presented externally.
