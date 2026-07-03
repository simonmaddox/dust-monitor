# dust — Hawcliffe Rd. air quality monitor

**Date:** 2026-07-03
**Status:** Approved

## Purpose

Monitor the EarthSense Leicestershire CC public air quality portal
(https://portal.earthsense.co.uk/LeicestershireCCPublic) and notify Simon when the
**Hawcliffe Rd., Mountsorrel** station reads elevated in **NO₂** or **PM2.5** compared
to the other stations in the network. Also maintain a complete local archive of hourly
readings, backfilled from the earliest data the API serves (July 2022).

## Background: the data source

The portal is a React SPA backed by JSON APIs at `https://service.earthsense.co.uk`.
All access verified working without special credentials:

- **Auth:** `GET /auth/api/authuser?auth=BASE64` where `BASE64` is
  `base64("LeicestershireCCPublic:LeicestershireCCPublic")` (public portals use the
  portal slug as both username and password). Returns `{token, expires}` — a JWT valid
  ~1 week. Fetch a fresh token every run; do not cache.
- **Stations:** `GET /zephyr/api/v2/getzephyrs` with `Authorization: Bearer <token>`.
  Returns ~20 units; the real sensors are `type == 0` with a non-null `alias`.
  Currently: 682 "Hawcliffe Rd., Mountsorrel", 856 "Ashby Rd., Loughborough",
  1137 "Wolsey Way, Loughborough", 616 "Whetstone Way, Whetstone",
  1754 "Cobden Primary School, Loughborough".
- **Measurements:**
  `GET /zephyr/api/v2/measurementdata/{zNumber}/{start}/{end}/AB/1/MyAirLocation/production`
  with bearer token; `start`/`end` are `YYYYMMDDHHmm` (UTC). Averaging id `1` =
  "Hourly average on the hour". Response nests species under
  `data → "Hourly average on the hour" → slotA/slotB → {species} → data[]`, parallel to
  `dateTime.data[]`. Merge slotA and slotB (either may be null per station). Species of
  interest: `NO2` and `particulatePM25`, both µg/m³. Data available back to July 2022;
  a station-week returns in ~1 s, month-sized chunks are fine.

## Architecture

A single dependency-free Ruby script (`monitor.rb`, stdlib only: `net/http`, `json`,
`csv`, `time`) with two modes, run by a GitHub Actions workflow:

- **`ruby monitor.rb run`** (hourly, cron `15 * * * *`): authenticate → discover
  stations → fetch recent hours → append new completed hours to the history archive →
  evaluate rules → update episode state → notify on new episodes → commit changed files.
- **`ruby monitor.rb backfill`** (one-off, run locally or via manual workflow dispatch):
  walk month-by-month from each station's `locationStartTimeDate` (earliest ~2022-06)
  to now and populate the archive. Idempotent: skips hours already recorded, so it can
  resume after interruption.
- **`ruby monitor.rb run --dry-run`**: fetch live data and print the full evaluation;
  writes no state, sends no notifications.

The workflow runs at :15 past the hour so the previous hour's average has settled.

## Station discovery

Stations are discovered dynamically each run from `getzephyrs` (`type == 0`, alias
present). The **target** is the station whose alias contains `"Hawcliffe"`; all other
discovered stations form the **comparison set**. If the council adds, renames, or
retires sensors the monitor adapts; if no Hawcliffe station is found, the run fails
loudly. The id→alias mapping is persisted to `stations.json` so history columns stay
interpretable.

## Detection rules

Evaluated per **completed UTC hour** (never the in-progress hour), and only for hours
where **≥ 2 comparison stations** report the species; hours with fewer are skipped and
never count as elevated. `mean` is the arithmetic mean of the comparison stations'
values for that hour.

| Species | Hour qualifies when | Sustained for |
|---|---|---|
| NO₂ | Hawcliffe ≥ 2.5 × mean **and** Hawcliffe − mean ≥ 30 µg/m³ | 2 consecutive qualifying hours |
| PM2.5 (`particulatePM25`) | Hawcliffe ≥ 1.5 × mean **and** Hawcliffe − mean ≥ 5 µg/m³ | 2 consecutive qualifying hours |

Thresholds were calibrated against 5 weeks of history (2026-05-28 → 2026-07-03): the
NO₂ rule fired ~9 episodes in 36 days (Hawcliffe genuinely spikes to 2–3× its
neighbours several times a week, peaking at 235 µg/m³); the PM2.5 rule fired zero
times (PM2.5 tracks regionally, so any firing is meaningful). Thresholds are named
constants at the top of `monitor.rb`, independent per species, retunable against the
archive.

## Episode state

`state.json` tracks, per species: `active` (bool), `since` (first qualifying hour of
the episode), `last_alert` (ISO timestamp).

- **Alert fires** only on the transition inactive → active (2 consecutive qualifying
  hours found in the evaluated window while `active` is false).
- **Episode ends** (`active` → false, re-arming alerts) when the most recent
  **6 completed hours** contain **no** qualifying hour.
- NO₂ and PM2.5 episodes are fully independent.
- Missing or malformed `state.json` is treated as "no active episodes" (fresh start),
  never a crash. On a fresh start the evaluation window comes from the archive, so
  state is derived from real recent history rather than cold.

## EU legal limit checks (amendment, 2026-07-03; revised same day)

In addition to the relative elevation rules, every run checks Hawcliffe's absolute
levels against the EU limit values **currently in force** (Directive 2008/50/EC,
carried by the 2024/2881 recast until 1 Jan 2030). Originally the stricter 2030
values were used; revised on request so alerts mean "this is over the limit that
applies today". The 2030 values and changeover are documented in the README, and
the daily-mean machinery stays implemented (tested via config injection) but
unconfigured until then.

| Species | Period | Limit | Allowed exceedances |
|---|---|---|---|
| NO₂ | 1 hour | 200 µg/m³ | 18 / calendar year |
| NO₂ | calendar year mean | 40 µg/m³ | — |
| PM2.5 | calendar year mean | 25 µg/m³ | — |

- **Counts are stateless**: year-to-date exceedance tallies are recomputed from the
  archive on every run; only alert *dedupe* lives in state.
- **Daily means** count only UTC days with ≥ 18 of 24 hourly values (the directive's
  75 % data-capture rule). Only completed days are evaluated.
- **Annual means** are calendar-year-to-date, evaluated only once ≥ 720 hourly values
  (~30 days) exist for the year.
- **Dedupe** (`state.json`, new `limits` section): hourly/daily checks store the most
  recent exceedance already alerted (`last_alerted`); an alert fires only for
  exceedances newer than that, and one alert covers all new exceedances since, with
  the year-to-date count vs the allowance in the title (e.g. "5th exceedance this
  year, 3 permitted"). On first deployment (`last_alerted` null) the baseline is the
  start of the evaluation window (hourly) / two days ago (daily), so historical
  exceedances never back-fire. Annual checks alert once per species per calendar year
  (`alerted_year`).
- Alert bodies note these are the 2030-applicable EU limits, not current UK law.

## Plausibility filter (amendment, 2026-07-03)

The Hawcliffe PM2.5 sensor malfunctioned for ~432 hours in mid-2025 (readings up to
2,813 µg/m³). All evaluation — elevation rules, limit checks, means — first drops
implausible readings: negative values, NO₂ > 1,000 µg/m³, PM2.5 > 500 µg/m³.
The archive keeps raw values untouched; filtering happens at read/evaluation time.

## Daily digest (amendment, 2026-07-03 — supersedes hourly alerting)

The monitor moves from hourly alert runs to a **daily digest**:

- **Cadence**: cron `15 6 * * *` (06:15 UTC), after the previous UTC day settles.
  Manual dispatch modes unchanged. Data still self-heals across any gap.
- **Reporting period**: all complete UTC days since `state.last_digest_day`
  (normally one; capped at 7 after outages). Re-runs the same day are no-ops for
  notification.
- **Noteworthy test** — an issue is opened only if the period contains at least one:
  - **elevation episode**: a qualifying run (existing calibrated rules, ≥ 2
    consecutive hours) starting after `state.since` for that species. The hourly
    model's staleness suppression, `active` flag and 6-hour re-arm are removed —
    retrospective reporting is the point. Multiple episodes are each listed with
    start–end (London time), peak value and the comparators' mean at the peak.
    Runs extending into the current day are included (marked ongoing) and deduped
    from the next digest by `since`.
  - **limit event**: new NO₂ hour(s) over 200 µg/m³ (baseline: start of the report
    period on first run), or an annual-mean crossing. In-force limits unchanged.
  - **data problem at Hawcliffe**: a reported day with < 18 of 24 hourly values, or
    any implausible readings filtered that day.
- **Digest content**: one issue titled `Air quality digest — Hawcliffe Rd, <date>`
  (or date range), with only the sections that occurred, plus a context table of
  daily mean NO₂/PM2.5 for every station on each reported day.
- **State** (`state.json`): per species `{since}` only; plus `last_digest_day` and
  the existing `limits` section. Old keys (`active`, `last_alert`) are ignored on
  load. State is written after successful notification, as before.
- Quiet days: archive and state still update; nothing is posted; the run prints its
  evaluation to the Actions log.

## History CSV columns (amendment, 2026-07-03)

Columns use **human-readable slugs**, not station numbers: `no2_hawcliffe_rd_mountsorrel`,
`pm25_ashby_rd_loughborough`, … A station's slug is derived from its alias
(lowercase, non-alphanumerics → `_`) the first time it is seen and **pinned** in
`stations.json` (`{"682": {"alias": "Hawcliffe Rd., Mountsorrel", "slug":
"hawcliffe_rd_mountsorrel"}}`), so later council renames never fork columns.
Slug collisions get a numeric suffix. A one-off `migrate-columns` CLI mode rewrites
existing CSV headers from `no2_<id>` to slug form (idempotent; values untouched).
The README documents the data format.

## Notifications

A minimal notifier interface: `notify(title, body)`. Implementations:

1. **GitHubIssueNotifier** (default): opens an issue on this repo via the REST API
   using the workflow's `GITHUB_TOKEN` (`GITHUB_REPOSITORY` env identifies the repo).
   GitHub's own notification routing (email/push) delivers it to Simon — working
   alerts with zero external services. Channel choice (ntfy/Pushover/email/etc.) is
   deliberately deferred; adding one later means one small class.
2. **ConsoleNotifier**: always active, prints to stdout (visible in the Actions log;
   the only notifier in `--dry-run`).

Alert content: title like
`NO₂ elevated at Hawcliffe Rd: 142 µg/m³ vs 45 across other stations (3.2×)`;
body contains a markdown table of the last 6 hours for all stations (times shown in
Europe/London), the rule that fired, and a link to the portal.

## History archive

- `history/<year>.csv`, wide format:
  `hour_utc,no2_682,pm25_682,no2_856,pm25_856,…` — one row per UTC hour, columns keyed
  by station id (mapping in `stations.json`). Empty cell = no reading. New stations
  append new columns; the CSV writer rewrites the year file when the column set grows.
- Full archive is ≈ 35k hours × 5 stations ≈ a few MB — fine in git.
- Every hourly run appends **all** completed hours missing since the last recorded
  row (not just the latest), so missed runs self-heal. Normal runs fetch a lookback
  window of 12 hours; if the archive's newest row is older than that, the run extends
  its fetch to cover the gap.

## GitHub Actions workflow

`.github/workflows/monitor.yml`:

- `schedule: cron '15 * * * *'` plus `workflow_dispatch` with an input to select mode
  (`run` | `backfill` | `dry-run`).
- Permissions: `contents: write` (commit state/history), `issues: write` (alerts).
- Steps: checkout → run `monitor.rb` (system Ruby on `ubuntu-latest`) → commit & push
  `state.json`, `stations.json`, `history/` **only if changed** (single commit, message
  like `monitor: 2026-07-03T14:15Z`).
- Concurrency group prevents overlapping runs (backfill vs hourly).

## Error handling

- HTTP calls retry once with a short backoff; a run that still fails exits non-zero so
  the workflow shows red and GitHub emails on repeated failure. No partial state is
  written on failure.
- A station returning no/partial data simply contributes nothing to the hours it's
  missing; rules handle it via the ≥ 2 comparators requirement.
- Notifier failure (e.g. issue creation fails) also fails the run — state is written
  *after* successful notification so a failed alert retries next run rather than being
  silently swallowed.

## Testing

- Rule evaluation and episode-transition logic are pure functions over plain hashes
  (`{hour → {station_id → value}}` in, qualifying hours / transitions out) — no I/O.
- Minitest (stdlib) in `test/monitor_test.rb` with JSON fixtures, including a replay of
  the real 2026-06-23 NO₂ spike (Hawcliffe 235 µg/m³ vs 77 mean) asserting exactly one
  alert per episode, plus cases for: insufficient comparators, single non-sustained
  spike (no alert), episode end + re-arm, PM2.5/NO₂ independence, and cold start.
- `--dry-run` mode for manual live verification.

## Repo layout

```
dust/
  monitor.rb                      # everything: fetch, rules, episodes, archive, notify
  state.json                      # episode state (committed by workflow)
  stations.json                   # station id → alias mapping
  history/2022.csv … 2026.csv     # hourly archive
  test/monitor_test.rb
  .github/workflows/monitor.yml
  docs/superpowers/specs/         # this document
```

## Out of scope (deliberately)

- Charts/dashboards, other pollutants, other stations as targets, smarter baselines
  (hour-of-day norms) — the archive makes all of these possible later.
- Choice of final notification channel (GitHub Issues serves until then).
