# Hawcliffe Rd. vs the portal's own PM2.5 colourscale

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

No statistical tricks: their scale, their sensor, their words.

## Caveats (use them or lose the argument)

- Hourly PM2.5 over 15 is common across urban Britain, especially winter evenings.
  The force of the stat is (a) the WHO-vs-UK-law gap and (b) the within-network
  contrast — not that Mountsorrel is uniquely smoky.
- The map colours near-real-time values; this analysis applies the same bands to
  hourly means, which is the closest archival equivalent.
- A council may fairly respond that the colourscale is a communication device, not
  a standard. That is precisely the point worth making to a legislator: the
  communication device tracks WHO health guidance; the legal standard does not.

## Reproduce

Band counts from `history/*.csv` (values ≥0 and ≤500, fault window
2025-06-21..2025-07-09 excluded, `pm25_*` columns); see the repo README "Data
format". The tables above were generated with a ~40-line Python loop over the
CSVs applying the band edges verbatim.
