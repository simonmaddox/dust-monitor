# dust

Monitors air quality at **Hawcliffe Rd., Mountsorrel** (Leicestershire, UK) and posts
a **daily digest** when something noteworthy happened: PM2.5 at the station was
*unusually elevated compared to its neighbours*, it went *over the EU legal limits*,
or its data looks broken. Data comes from Leicestershire County Council's public
[EarthSense portal](https://portal.earthsense.co.uk/LeicestershireCCPublic); the
monitor runs unattended on GitHub Actions and notifies by opening a GitHub Issue on
this repo. Quiet days produce nothing — a notification always means something.

## How it works

Every morning at 06:15 UTC the workflow:

1. Authenticates against the EarthSense API (public portals use the portal slug as
   both username and password — there are no secrets in this repo).
2. Discovers the network's stations, fetches recent hourly averages (all
   channels), and appends them to the archive in `history/` (complete hourly data back to March
   2021; missed runs self-heal).
3. Evaluates the previous UTC day (or days, after an outage) against the rules below.
4. If anything is noteworthy, opens a single digest issue with only the sections that
   occurred plus a table of every station's daily means; commits updated data either way.

Implausible readings (negative, NO₂ > 1,000 µg/m³, PM2.5 > 500 µg/m³) are excluded
from evaluation and *reported as data problems* — the Hawcliffe PM2.5 sensor once
spent weeks in 2025 claiming up to 2,813 µg/m³. Raw values stay in the archive.

### Digest triggers

Alerting covers **PM2.5 only** (see "Why NO₂ isn't alerted" below).

**Elevated vs the other stations** — a run of ≥ 2 consecutive hours where Hawcliffe
is far above the average of the other stations (threshold calibrated on 5 weeks of
real data):

| Species | Threshold |
|---|---|
| PM2.5 | ≥ 1.5× the others' mean **and** ≥ 5 µg/m³ above it |

**Over the EU legal limits** — the values currently in force (Directive 2008/50/EC,
carried by the 2024 recast until 2030), with year-to-date tallies recomputed from
the archive:

| Species | Period | Limit |
|---|---|---|
| PM2.5 | calendar year mean | 25 µg/m³ |

**Data problems** — a day where Hawcliffe reported fewer than 18 of 24 hourly PM2.5
values, or where implausible readings had to be filtered.

### Why NO₂ isn't alerted

The monitor originally alerted on NO₂ too (elevation ≥ 2.5× + 30 µg/m³; the in-force
limits of 200 µg/m³/hour with 18 permitted exceedances and 40 µg/m³ annual mean — the
archive records 19 exceedance hours in December 2021, peak 386 µg/m³). In July 2026,
Charnwood Borough Council's environmental health team advised that the station's
siting — inside the county council's highways depot, where close-proximity vehicle
exhaust interferes with readings — does not meet NO₂ monitoring deployment
guidelines, that the NO₂ channel is an inherent feature of the instrument rather
than something deployed for assessment, and that its raw output cannot support
conclusions about air quality at locations where people are exposed.

NO₂ alerting was therefore removed on 10 July 2026. The channel is **still
archived in full** — as an indicator of combustion activity near the monitor it
remains useful for source analysis — but the monitor no longer treats it as an
air-quality signal. The limit values stay documented (and tested) in `monitor.rb`
as dormant machinery.

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

This matters locally for PM2.5: Hawcliffe's 2025 annual mean (9.2 µg/m³) sits just
under the 2030 annual limit. (The NO₂ rows are shown for completeness; NO₂ at this
site is archived but not evaluated — see "Why NO₂ isn't alerted".)
The daily-mean machinery is implemented and tested; if these values are ever
adopted, updating the `LIMITS` constant at the top of `monitor.rb` is the only
change needed.

**The UK is not bound by the 2024 directive post-Brexit** (adopted after the
transition period; nor does it apply in Northern Ireland). The UK's actual
trajectory: the Air Quality Standards Regulations 2010 carry the "Now" column
forward as assimilated law, and for PM2.5 England has its own binding path under
the Environmental Targets (Fine Particulate Matter) (England) Regulations 2023 —
an interim **12 µg/m³ annual mean by 2028** and **10 µg/m³ by 2040**, reaching
the EU's 2030 number a decade later. There are currently no plans to tighten the
NO₂ limits. The monitor therefore alerts against the limits in force in the UK
today; the 2030 values serve as a health-based benchmark, not a UK compliance
claim.

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
  implausible values (500–2,813 µg/m³, flat-topped, one station only) from
  2025-06-21T06:00Z to 2025-07-09T15:00Z — outside that fault window, no station
  has recorded a single PM2.5 hour above 500 in five years, which is why the
  plausibility filter uses that cutoff (treat the fault's edges, 17–20 June, with
  caution too: an earlier data revision published by CBC shows elevated values
  there); the `no` channel reports real values in 2021–2023 but near-constant
  zero after; and `o3` readings during NO₂ spikes are unreliable (electrochemical
  cross-interference); and the quarry's compliance consultant documented the
  Hawcliffe Zephyr's PM channels reading consistently low during February 2022. The
  Hawcliffe NO₂ baseline also **steps up ~40% in February 2024** (Hawcliffe-only;
  neighbours flat) — likely a recalibration/cartridge change; treat cross-year
  NO₂ trend comparisons at this station with caution.
  Raw values are kept regardless — filter, don't edit.
- EarthSense appears to recalibrate data retrospectively (CBC's published daily
  export disagrees with the current feed for 19–20 June 2025), so archived values
  reflect the feed *as it was when fetched*. This is a feature: the archive
  preserves a record that the upstream feed may later revise.
- Stations appear from their install dates (Hawcliffe/March 2021 onward; the full
  five-station network from 2026).

## Running it

```
ruby monitor.rb run             # one digest pass (fetch, evaluate, notify, save)
ruby monitor.rb run --dry-run   # same, but print the digest and write nothing
ruby monitor.rb backfill        # (re)populate history/ from the API's full history
ruby monitor.rb migrate-columns # one-off: rewrite old id-based CSV headers to slugs
ruby test/monitor_test.rb       # test suite
ruby tools/dustcheck.rb 2025-08-12          # cross-reference a dust-diary entry
```

Working analyses (source attribution, colourscale comparisons, event
investigations) live in `analysis/`.

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
environmental data; Charnwood Borough Council already publishes the same
monitor's data (daily means, all channels) as unrestricted downloads on its
[Mountsorrel Quarry page](https://www.charnwood.gov.uk/pages/mountsorrel_quarry),
with which this archive is consistent. The sensors are indicative instruments,
not reference-grade analysers, so treat values accordingly. If you are the data
owner and would like anything changed or removed, please open an issue.

The **code** is released under the [MIT License](LICENSE). The MIT licence covers
the software only, not the measurement data described above.
