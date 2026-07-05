# dust

Monitors air quality at **Hawcliffe Rd., Mountsorrel** (Leicestershire, UK) and posts
a **daily digest** when something noteworthy happened: the station was *unusually
elevated compared to its neighbours*, it went *over the EU legal limits*, or its data
looks broken. Data comes from Leicestershire County Council's public
[EarthSense portal](https://portal.earthsense.co.uk/LeicestershireCCPublic); the
monitor runs unattended on GitHub Actions and notifies by opening a GitHub Issue on
this repo. Quiet days produce nothing — a notification always means something.

## How it works

Every morning at 06:15 UTC the workflow:

1. Authenticates against the EarthSense API (public portals use the portal slug as
   both username and password — there are no secrets in this repo).
2. Discovers the network's stations, fetches recent hourly NO₂/PM2.5 averages, and
   appends them to the archive in `history/` (complete hourly data back to March
   2021; missed runs self-heal).
3. Evaluates the previous UTC day (or days, after an outage) against the rules below.
4. If anything is noteworthy, opens a single digest issue with only the sections that
   occurred plus a table of every station's daily means; commits updated data either way.

Implausible readings (negative, NO₂ > 1,000 µg/m³, PM2.5 > 500 µg/m³) are excluded
from evaluation and *reported as data problems* — the Hawcliffe PM2.5 sensor once
spent weeks in 2025 claiming up to 2,813 µg/m³. Raw values stay in the archive.

### Digest triggers

**Elevated vs the other stations** — a run of ≥ 2 consecutive hours where Hawcliffe
is far above the average of the other stations (thresholds calibrated on 5 weeks of
real data):

| Species | Threshold |
|---|---|
| NO₂ | ≥ 2.5× the others' mean **and** ≥ 30 µg/m³ above it |
| PM2.5 | ≥ 1.5× the others' mean **and** ≥ 5 µg/m³ above it |

**Over the EU legal limits** — the values currently in force (Directive 2008/50/EC,
carried by the 2024 recast until 2030), with year-to-date exceedance tallies
recomputed from the archive:

| Species | Period | Limit | Permitted exceedances |
|---|---|---|---|
| NO₂ | 1 hour | 200 µg/m³ | 18 per calendar year |
| NO₂ | calendar year mean | 40 µg/m³ | — |
| PM2.5 | calendar year mean | 25 µg/m³ | — |

Hawcliffe has breached this regime once in the archive: 19 exceedance hours in 2021
(peak 386 µg/m³) against the 18 permitted.

**Data problems** — a day where Hawcliffe reported fewer than 18 of 24 hourly values,
or where implausible readings had to be filtered.

## What changes in 2030

Directive (EU) 2024/2881 replaces the current limits on **1 January 2030** with much
stricter ones, aligned closer to WHO guidance:

| Species | Period | Now | From 2030 |
|---|---|---|---|
| NO₂ | 1 hour | 200 µg/m³, 18 exceedances/yr | 200 µg/m³, only **3** exceedances/yr |
| NO₂ | 1 day | *no limit* | **50 µg/m³**, 18 exceedances/yr |
| NO₂ | year | 40 µg/m³ | **20 µg/m³** |
| PM2.5 | 1 day | *no limit* | **25 µg/m³**, 18 exceedances/yr |
| PM2.5 | year | 25 µg/m³ | **10 µg/m³** |

This matters locally: Hawcliffe's current behaviour would already breach the 2030
hourly NO₂ rule (4 exceedance hours by June 2026, vs 3 permitted per year), and its
2025 annual means (NO₂ 18.6, PM2.5 9.2 µg/m³) sit just under the 2030 annual limits.
The daily-mean machinery is implemented and tested; when the 2030 values take
effect, updating the `LIMITS` constant at the top of `monitor.rb` is the only change
needed. (The UK is not bound by the 2024 directive post-Brexit; current UK law
retains the same values as the "Now" column.)

## Findings so far

The archive has already surfaced things worth knowing: 19 hours over the legal
NO₂ hourly limit in December 2021 (peak 386 µg/m³), a three-week PM2.5 sensor
fault in mid-2025 still visible in the public feed, and a recurring
working-hours pattern of large NO₂ spikes in 2026. The evidence — with charts,
eliminated alternative explanations, and corroboration from the quarry's own
compliance monitoring — is written up for the local authorities in
[`reports/2026-07-04-council-evidence/report.md`](reports/2026-07-04-council-evidence/report.md).

## Data format

`history/<year>.csv` — one row per UTC hour, one file per year:

```
hour_utc,no2_hawcliffe_rd_mountsorrel,pm25_hawcliffe_rd_mountsorrel,no2_ashby_rd_loughborough,...
2026-06-23T19:00:00Z,235.58,9.22,18.41,...
```

- `hour_utc` — start of the hour, UTC, ISO 8601. Values are hourly means in µg/m³.
- Columns are `<species>_<station slug>`; the slug is assigned from the station's
  name the first time it is seen and **pinned** in `stations.json` (which maps
  EarthSense station ids to `{alias, slug}`), so later renames never fork columns.
- Species: `no2`, `pm25` (the alerting pair), plus archive-only `pm10` (coarse
  dust — `pm10 − pm25` is the "dust on cars" fraction), `pm1` (fine/combustion
  fraction), `no` (fresh-exhaust tracer; a high NO/NO₂ ratio indicates a nearby
  source), and `o3`. Columns before July 2026 were backfilled retrospectively.
- An empty cell means no reading. Values are raw as served by the API — including
  implausible ones; filtering happens at evaluation time, not in the archive.
- Known data quirks to respect when analysing: the Hawcliffe PM2.5 channel served
  impossible values (500–2,813 µg/m³) from 2025-06-21T06:00Z to 2025-07-09T15:00Z;
  the `no` channel reports real values in 2021–2023 but near-constant zero after;
  and `o3` readings during NO₂ spikes are unreliable (electrochemical
  cross-interference). Raw values are kept regardless — filter, don't edit.
- Stations appear from their install dates (Hawcliffe/March 2021 onward; the full
  five-station network from 2026).

## Running it

```
ruby monitor.rb run             # one digest pass (fetch, evaluate, notify, save)
ruby monitor.rb run --dry-run   # same, but print the digest and write nothing
ruby monitor.rb backfill        # (re)populate history/ from the API's full history
ruby monitor.rb migrate-columns # one-off: rewrite old id-based CSV headers to slugs
ruby test/monitor_test.rb       # test suite
```

Plain Ruby stdlib (2.6+), no gems. The workflow (`.github/workflows/monitor.yml`)
runs daily at 06:15 UTC and can be dispatched manually in `run`, `dry-run`, or
`backfill` mode. To restore immediate (hourly) alerting instead of the daily digest,
set the cron back to `15 * * * *` and see the git history of the digest change for
the previous episode semantics.

Design docs: `docs/superpowers/specs/` (what and why, including threshold
calibration), `docs/superpowers/plans/` (how it was built).

## Data attribution & licensing

The measurements in `history/` originate from **Zephyr® sensors operated by
[EarthSense Systems Ltd](https://www.earthsense.co.uk/)** on behalf of
**Leicestershire County Council**, retrieved from the council's freely accessible
public portal. This repository republishes them in good faith as public-interest
environmental data; the sensors are indicative instruments, not reference-grade
analysers, so treat values accordingly. If you are the data owner and would like
anything changed or removed, please open an issue.

The **code** is released under the [MIT License](LICENSE). The MIT licence covers
the software only, not the measurement data described above.
