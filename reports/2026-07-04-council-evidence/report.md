# Air quality at Hawcliffe Rd., Mountsorrel — observations from the council's public monitoring data

**Prepared:** 4 July 2026
**Prepared by:** Simon Maddox (resident)
**Data source:** Leicestershire County Council's public EarthSense air quality portal
(https://portal.earthsense.co.uk/LeicestershireCCPublic), hourly-average NO₂ and PM2.5
from the council's five Zephyr® sensors, March 2021 – July 2026 (~46,000 hourly records).
The full extracted dataset and methodology are available on request.

## Summary

Analysis of the council's own published data for the **Hawcliffe Rd., Mountsorrel**
station shows three things I believe warrant attention:

1. **December 2021: 19 hours over the legal NO₂ hourly limit** — more than the
   18 hours permitted per calendar year, i.e. a breach of the limit-value regime
   in that year (and the data only begins in March 2021).
2. **21 June – 9 July 2025: the station's PM2.5 sensor malfunctioned** and the
   portal still serves the faulty readings (432 hours of 500–2,813 µg/m³) with no
   flag, corrupting any averages computed from the public data.
3. **2026: recurring large NO₂ spikes** — four hours over 200 µg/m³ so far this
   year, in a distinctive working-hours/early-evening pattern that suggests a
   local intermittent source near the station.

## 1. December 2021 — legal limit breached

The UK objective for NO₂ allows the 1-hour mean to exceed 200 µg/m³ at most
**18 times per calendar year**. Hawcliffe Rd. recorded **19 exceedance hours in
2021**, all in December:

| Date (UTC) | Hours over 200 | Peak |
|---|---|---|
| 8 Dec 2021 | 10:00, 11:00 | 251 |
| 17 Dec 2021 | 10:00 | 222 |
| 18 Dec 2021 | 10:00–15:00 (6 consecutive hours) | **386** |
| 19 Dec 2021 | 10:00 | 204 |
| 28 Dec 2021 | 10:00–12:00 | 299 |
| 29 Dec 2021 | 10:00–14:00 | 214 |
| 31 Dec 2021 | 09:00 | 208 |

![December 2021 NO₂ at Hawcliffe Rd.](chart1-dec-2021-no2.png)

Note the consistent 09:00–15:00 timing. No other network station reported
comparable levels (the second station in the network came online mid-2022, so
December 2021 has no co-located comparison — a further reason reference-grade
verification at this location would be valuable). Two further exceedance hours
occurred on 4 January 2023 (258 and 242 µg/m³, again at 09:00–10:00), then none
until 2026.

## 2. June–July 2025 — faulty PM2.5 data still published

From **06:00 UTC on 21 June 2025 to 15:00 UTC on 9 July 2025** the Hawcliffe Rd.
PM2.5 channel reported physically impossible values — **432 hourly readings
between 500 and 2,813 µg/m³** across 19 days (normal levels at this station are
3–10 µg/m³; even severe wildfire smoke rarely exceeds a few hundred).

![2025 PM2.5 sensor fault](chart3-2025-pm25-fault.png)

These values are still served by the public portal and API without any quality
flag. Anyone using the public data naively — including for annual averages —
gets badly corrupted results (they inflate the station's 2025 annual PM2.5 mean
from ~9 µg/m³ to ~142 µg/m³). **Request:** ask EarthSense to flag or remove the
faulty period from the published feed, and confirm the sensor has been
recalibrated or replaced.

## 3. 2026 — recurring NO₂ spikes with a distinctive pattern

So far in 2026 Hawcliffe Rd. has recorded **four hours over the 200 µg/m³
hourly limit** (within the current 18/year allowance, but already exceeding the
3/year allowance that the EU's revised directive applies from 2030):

| Date | Time (UTC) | NO₂ |
|---|---|---|
| 25 May 2026 | 19:00 | 220 |
| 23 June 2026 | 18:00 | 211 |
| 23 June 2026 | 19:00 | **236** |
| 24 June 2026 | 18:00 | 206 |

![23–24 June 2026 episode](chart2-june-2026-episode.png)

The 23–24 June chart shows the signature: the whole network rises in the
evening, but Hawcliffe rises to **2.5–3× the average of the other four
stations**. Hawcliffe normally reads *below* its neighbours (median ratio 0.86),
so these are episodic, local events rather than a generally polluted location.
The hours when Hawcliffe runs far above the rest of the network cluster in
working hours and early evening:

![Time-of-day pattern](chart4-time-of-day.png)

That pattern — daytime/early-evening, weekday-style hours, highly localised to
one station — is consistent with an intermittent source close to the sensor
(e.g. site traffic, idling HGVs, or plant) rather than regional background.

## Caveats

- Zephyr sensors are **indicative** instruments, not reference-grade analysers;
  individual values carry uncertainty and formal compliance is assessed by
  reference methods. The patterns above are nonetheless strong and internally
  consistent (the same instrument reads low on normal days).
- All figures exclude implausible readings (the 2025 fault period is excluded
  from every calculation except section 2, which is about the fault itself).
- Times are UTC throughout; local time is UTC+1 in summer.

## Requests

1. Investigate the source of the recurring NO₂ spikes at Hawcliffe Rd.,
   particularly the 09:00–15:00 and 18:00–20:00 UTC clustering.
2. Correct or flag the 21 June – 9 July 2025 PM2.5 data in the public feed and
   confirm the sensor's current condition.
3. Consider whether the December 2021 breach and the 2026 spike pattern justify
   reference-grade NO₂ monitoring (e.g. a diffusion-tube survey or analyser) at
   or near this location under the council's Local Air Quality Management
   duties.

I'm happy to share the extracted dataset, the analysis code, or anything else
useful.
