# Hawcliffe Rd. vs the portal's own colourscales (PM2.5 and NO₂)

*Working analysis, 5 July 2026 — kept primarily as material for a future letter to
the MP about the gap between health-based communication scales and frozen UK legal
limits. Not part of the council evidence report.*

## The scale

The EarthSense portal's public map colours PM2.5 with these bands (µg/m³):
0–1.5 Exceptionally clean · 1.5–3 Very clean · 3–4.5 Very lightly polluted ·
4.5–6 Lightly polluted · 6–7.5 Light–moderately · 7.5–9 Moderately ·
9–10.5 Moderately–heavily · 10.5–12 **Heavily polluted** ·
12–13.5 **Very heavily polluted** · 13.5–15 **Extremely polluted** ·
15+ **Exceptionally polluted**.

Notably, the scale is WHO-anchored: "Exceptionally polluted" starts at the WHO
24-hour guideline (15), which is **40% below the UK legal annual limit (25)**, and
the WHO annual guideline (5) falls within "Lightly polluted".

## Hawcliffe Rd., hours per band by year

Plausibility-filtered; the 21 Jun – 9 Jul 2025 sensor-fault period excluded.

| Year | Heavily (10.5–12) | Very heavily (12–13.5) | Extremely (13.5–15) | Exceptionally (15+) | Total ≥10.5 | % of year |
|---|---|---|---|---|---|---|
| 2021 | 299 | 244 | 199 | 607 | 1,349 | 20.2% |
| 2022 | 268 | 237 | 216 | 1,107 | 1,828 | 20.9% |
| 2023 | 270 | 184 | 235 | 850 | 1,539 | 17.6% |
| 2024 | 306 | 236 | 209 | 985 | 1,736 | 19.9% |
| 2025 | 330 | 254 | 220 | 1,570 | 2,374 | **29.8%** |
| 2026 YTD | 137 | 75 | 84 | 566 | 862 | 19.6% |

"Exceptionally polluted" alone: **5,685 hours since March 2021** (12.6% of all
hours), touching 100–141 days in every full year.

## Network comparison, 2026 YTD (% of hours at or above threshold)

| Station | ≥10.5 | ≥12 | ≥13.5 | ≥15 |
|---|---|---|---|---|
| Wolsey Way, Loughborough | 20.6% | 17.8% | 15.5% | 13.2% |
| **Hawcliffe Rd., Mountsorrel** | 19.6% | 16.5% | 14.8% | 12.9% |
| Ashby Rd., Loughborough | 12.3% | 10.7% | 8.6% | 7.1% |
| Whetstone Way, Whetstone | 10.4% | 8.5% | 6.8% | 5.5% |
| Cobden Primary School | 7.9% | 5.2% | 4.0% | 2.5% |

The gradient is stable at every threshold: the two roadside/industrial-adjacent
sites run ~5× the school site's rate. So the numbers are not purely an artefact of
an aggressive scale — the ranking it produces is real.

## The key line

> The council's own public map tells residents the air at Hawcliffe Road is
> "exceptionally polluted" for roughly a thousand hours a year — while the law
> finds the same location compliant, with headroom, indefinitely.

No statistical tricks: their scale, their sensor, their words. Note the scope:
this is **PM2.5**, where UK law sets only an annual-mean limit (25 µg/m³) that
this location meets several times over — so "compliant indefinitely" is precise,
not rhetorical. NO₂ is the pollutant where the hourly objective has actually
been breached (December 2021; see the NO₂ section below) — keep the two claims
attached to the right pollutant when quoting.

## Caveats (use them or lose the argument)

- Hourly PM2.5 over 15 is common across urban Britain, especially winter evenings.
  The force of the stat is (a) the WHO-vs-UK-law gap and (b) the within-network
  contrast — not that Mountsorrel is uniquely smoky.
- The map colours near-real-time values; this analysis applies the same bands to
  hourly means, which is the closest archival equivalent.
- A council may fairly respond that the colourscale is a communication device, not
  a standard. That is precisely the point worth making to a legislator: the
  communication device tracks WHO health guidance; the legal standard does not.

## The NO₂ colourscale

The portal's NO₂ map bands run 0–4 (Exceptionally clean) in steps of 4 up to
**40+ = "Exceptionally polluted"**. The anchoring differs tellingly from PM2.5:
the top band starts at exactly the **UK annual legal limit (40)** — i.e. the map
calls an hour "exceptionally polluted" when it reaches the concentration the law
permits as a year-round *average* — while the WHO annual guideline (10) sits down
at the "Very lightly polluted" boundary.

### Hawcliffe Rd., NO₂ hours per band by year

| Year | Heavily (28–32) | Very heavily (32–36) | Extremely (36–40) | Exceptionally (40+) | Total ≥28 | % of year | Days with a 40+ hour |
|---|---|---|---|---|---|---|---|
| 2021 | 68 | 52 | 37 | 279 | 436 | 6.5% | 31 |
| 2022 | 216 | 135 | 77 | 128 | 556 | 6.4% | 51 |
| 2023 | 155 | 72 | 41 | 88 | 356 | 4.1% | 23 |
| 2024 | 317 | 204 | 112 | 236 | 869 | 10.0% | 77 |
| 2025 | 404 | 285 | 162 | 492 | 1,343 | **15.9%** | **102** |
| 2026 YTD | 96 | 92 | 34 | 278 | 500 | 11.4% | 50 |

**Trend caveat (added 5 Jul 2026 after decomposition)**: the apparent 2024–25
deterioration is substantially confounded by a **Hawcliffe-only baseline step in
February 2024** (monthly median 10.8 → 14.7 overnight; neighbouring stations
flat) — the signature of a sensor recalibration/cartridge change, not air. Band
counts near the thresholds are inflated from Feb 2024 onward. What survives the
caveat: the December 2021 breach (pre-step), all >200 µg/m³ exceedance hours
(13× the step size), and the 2026 corridor episodes (95% co-elevated with Wolsey
Way — a network-relative signal a local baseline step cannot create). Treat
"quadrupled since 2023" as unproven; the *episodic* deterioration in 2026 is
real.

### 2026 YTD network comparison, NO₂ (% of hours at/above threshold)

| Station | ≥28 | ≥32 | ≥36 | ≥40 |
|---|---|---|---|---|
| Wolsey Way, Loughborough | 31.4% | 24.4% | 19.4% | **15.8%** |
| **Hawcliffe Rd., Mountsorrel** | 11.4% | 9.2% | 7.1% | 6.3% |
| Cobden Primary School | 5.8% | 2.7% | 1.0% | 0.5% |
| Whetstone Way, Whetstone | 4.1% | 1.6% | 0.5% | 0.2% |
| Ashby Rd, Loughborough | 0.0% | 0.0% | 0.0% | 0.0% |

Two observations beyond Hawcliffe:

- **Wolsey Way is the network's NO₂ hotspot by a wide margin** — "exceptionally
  polluted" one hour in six, 2.5× Hawcliffe. (Consistent with its 261 µg/m³ hour
  on 23 June 2026.) Any borough-level advocacy should mention it.
- **Ashby Rd records *zero* hours at even 28 µg/m³ in 2026** — anomalously clean
  for a Loughborough roadside site and starkly divergent from Wolsey Way nearby.
  Worth a question about siting or sensor calibration before treating either as
  representative.

## Reproduce

Band counts from `history/*.csv` (values ≥0 and ≤500, fault window
2025-06-21..2025-07-09 excluded, `pm25_*` columns); see the repo README "Data
format". The tables above were generated with a ~40-line Python loop over the
CSVs applying the band edges verbatim.
