# dust

Monitors air quality at **Hawcliffe Rd., Mountsorrel** (Leicestershire, UK) and
raises an alert when it is either *unusually elevated compared to its neighbouring
stations* or *over the EU legal limits*. Data comes from Leicestershire County
Council's public [EarthSense portal](https://portal.earthsense.co.uk/LeicestershireCCPublic);
the monitor runs unattended on GitHub Actions every hour and alerts by opening a
GitHub Issue on this repo.

## How it works

Each hourly run:

1. Authenticates against the EarthSense API (public portals use the portal slug as
   both username and password — there are no secrets in this repo).
2. Discovers the network's stations dynamically, fetches the latest hourly averages
   for NO₂ and PM2.5, and appends them to the CSV archive in `history/` (complete
   hourly data back to March 2021; gaps self-heal on the next run).
3. Evaluates two kinds of rule (below) against the archive.
4. Opens a GitHub Issue for anything new, and commits the updated archive and
   episode state back to the repo.

Implausible sensor readings (negative, NO₂ > 1,000 µg/m³, PM2.5 > 500 µg/m³) are
ignored by all checks — the Hawcliffe PM2.5 sensor once spent several weeks in 2025
reporting up to 2,813 µg/m³. Raw values are kept in the archive untouched.

### Rule 1: elevated vs the other stations

Fires when Hawcliffe is far above the average of the network's other stations,
sustained for 2 consecutive hours:

| Species | Threshold (calibrated on 5 weeks of real data) |
|---|---|
| NO₂ | ≥ 2.5× the others' mean **and** ≥ 30 µg/m³ above it |
| PM2.5 | ≥ 1.5× the others' mean **and** ≥ 5 µg/m³ above it |

One alert per episode; it re-arms after 6 consecutive quiet hours.

### Rule 2: over the EU legal limits

Checks Hawcliffe's absolute levels against the EU limit values **currently in
force** (Directive 2008/50/EC, carried by the 2024 recast until 2030):

| Species | Period | Limit | Permitted exceedances |
|---|---|---|---|
| NO₂ | 1 hour | 200 µg/m³ | 18 per calendar year |
| NO₂ | calendar year mean | 40 µg/m³ | — |
| PM2.5 | calendar year mean | 25 µg/m³ | — |

Alerts include the year-to-date exceedance tally (recomputed from the archive, so
there are no counters to corrupt), e.g. *"NO₂ over EU hourly limit at Hawcliffe Rd:
236 µg/m³ (limit 200) — 5th exceedance this year, 18 permitted"*. Hawcliffe has
breached this regime once in the archive: 19 exceedance hours in 2021 (peak
386 µg/m³) against the 18 permitted.

## What changes in 2030

Directive (EU) 2024/2881 replaces these limits on **1 January 2030** with much
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
The daily-mean checking machinery is already implemented and tested; when the 2030
values take effect, updating the `LIMITS` constant at the top of `monitor.rb` is the
only change needed.

(The UK is not bound by the 2024 directive post-Brexit; current UK law retains the
same values as the "Now" column.)

## Running it

```
ruby monitor.rb run             # one monitoring pass (fetch, evaluate, alert, save)
ruby monitor.rb run --dry-run   # same, but print the evaluation and write nothing
ruby monitor.rb backfill        # (re)populate history/ from the API's full history
ruby test/monitor_test.rb       # test suite
```

Plain Ruby stdlib (2.6+), no gems. The GitHub Actions workflow
(`.github/workflows/monitor.yml`) runs `monitor.rb run` hourly at :15 and can be
dispatched manually in `run`, `dry-run`, or `backfill` mode.

Design docs: `docs/superpowers/specs/` (what and why, including threshold
calibration), `docs/superpowers/plans/` (how it was built).
