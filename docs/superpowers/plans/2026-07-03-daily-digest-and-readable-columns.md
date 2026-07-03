# Daily Digest + Readable CSV Columns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move from hourly alert runs to a once-daily noteworthy-only digest, and rename history CSV columns from `no2_682` to pinned human-readable slugs (`no2_hawcliffe_rd_mountsorrel`).

**Architecture:** `Episodes` shrinks to run-detection + since-dedupe (no active/re-arm). `Monitor#run` ends in `#digest` instead of `#evaluate`. `stations.json` becomes `{id => {alias, slug}}` with slugs pinned on first sight; a `migrate-columns` CLI mode rewrites existing CSV headers. Spec amendments "Daily digest" and "History CSV columns" are the authority.

**Tech Stack:** unchanged (Ruby 2.6+ stdlib, Minitest).

## Global Constraints

- Constants: delete `QUIET_HOURS`, `LOOKBACK_HOURS`; add `CONTEXT_HOURS = 6`, `FETCH_MIN_HOURS = 42`, `DIGEST_MAX_DAYS = 7`. `DAILY_MIN_HOURS` (18) doubles as the data-problem threshold.
- Slug rule: `alias.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')`; collision → append `_<id>`.
- Old `state.json` keys (`active`, `last_alert`) are ignored on load; `since` carries over.
- Cron becomes `15 6 * * *`. Digest dedupe via `state['last_digest_day']`.
- Test command `ruby test/monitor_test.rb`; commit per green cycle with standard trailers.

---

### Task 1: Slugs + station registry + slug-keyed columns

**Files:** `monitor.rb`, `test/monitor_test.rb`.

**Produces:** `Dust.slugify(name)`; `Monitor#station_registry(stations)` (private, returns and pins `{id_str => {'alias','slug'}}`, reading legacy `{id => alias}` stations.json transparently); `Monitor#rows_for`/backfill/digest all address columns as `"#{species}_#{slug}"`; both `run` and `backfill` persist `stations.json` in the new format (not in dry-run).

- [ ] Failing tests: `Dust.slugify('Hawcliffe Rd., Mountsorrel') == 'hawcliffe_rd_mountsorrel'`; slugify strips edge junk (`'(Test) Site!' → 'test_site'`); MonitorTest fixture updated to assert `stations.json` new shape (`{'682' => {'alias' => ..., 'slug' => 'hawcliffe_rd_mountsorrel'}}`) and history CSV headers contain `no2_hawcliffe_rd_mountsorrel`; legacy stations.json (string values) upgraded without changing slugs; collision test (two stations, same alias) gets `_<id>` suffix.
- [ ] Implement → green → commit `feat: human-readable slug columns pinned in stations.json`.

```ruby
  def self.slugify(name)
    name.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
  end

    # Monitor private:
    def station_registry(stations)
      path = File.join(@root, 'stations.json')
      reg = {}
      if File.exist?(path)
        JSON.parse(File.read(path)).each do |id, v|
          reg[id] = v.is_a?(Hash) ? v : { 'alias' => v, 'slug' => Dust.slugify(v) }
        end
      end
      stations.each do |z|
        id = z['zNumber'].to_s
        if reg[id]
          reg[id] = reg[id].merge('alias' => z['alias'])
        else
          slug = Dust.slugify(z['alias'])
          slug = "#{slug}_#{id}" if reg.values.any? { |v| v['slug'] == slug }
          reg[id] = { 'alias' => z['alias'], 'slug' => slug }
        end
      end
      reg
    end

    def col(species, z_or_id)
      id = z_or_id.is_a?(Hash) ? z_or_id['zNumber'].to_s : z_or_id.to_s
      "#{species}_#{@registry[id]['slug']}"
    end
```
`rows_for` uses `col(SPECIES[sp], station)`. `run`/`backfill` set `@registry = station_registry(stations)` up front and `write_json('stations.json', @registry) unless @dry_run`.

---

### Task 2: `migrate-columns` CLI mode

**Files:** `monitor.rb`, `test/monitor_test.rb`.

**Produces:** `Monitor#migrate_columns` + CLI `ruby monitor.rb migrate-columns`: loads stations.json (normalising legacy format and saving it back), rewrites every `history/*.csv` header cell matching `/\A(no2|pm25)_(\d+)\z/` to `\1_<slug>`; idempotent; values untouched; unknown ids left alone with a warning.

- [ ] Failing test: temp dir with legacy stations.json + a CSV headed `hour_utc,no2_682,pm25_682`; after `migrate_columns` header is `hour_utc,no2_hawcliffe_rd_mountsorrel,pm25_hawcliffe_rd_mountsorrel`, row values unchanged, stations.json upgraded; running it again changes nothing.
- [ ] Implement → green → commit `feat: migrate-columns mode for history headers`.

```ruby
    def migrate_columns
      @registry = station_registry([])   # normalise existing file, no API needed
      write_json('stations.json', @registry)
      Dir[File.join(@root, 'history', '*.csv')].sort.each do |path|
        rows = CSV.read(path)
        rows[0] = rows[0].map do |c|
          m = c.match(/\A(no2|pm25)_(\d+)\z/)
          if m && @registry[m[2]]
            "#{m[1]}_#{@registry[m[2]]['slug']}"
          else
            warn "unknown station id in #{File.basename(path)}: #{c}" if m
            c
          end
        end
        CSV.open(path, 'w') { |csv| rows.each { |r| csv << r } }
        puts "migrated #{File.basename(path)}"
      end
    end
```

---

### Task 3: Episodes → runs + since-dedupe

**Files:** `monitor.rb`, `test/monitor_test.rb`.

**Produces:** `Episodes.runs(hours, qualifying)` → `[{start:, last:, len:}]` (maximal adjacent runs, len ≥ PERSIST_HOURS); `Episodes.new_runs(hours, qualifying, since)` filters `start > since` (nil since = all). **Deletes** `Episodes::EMPTY`, `.step`, `.live_run_start`, `QUIET_HOURS`, and `EpisodesTest`.

- [ ] Failing tests (replace EpisodesTest with RunsTest): detects a 2h run; ignores 1h spikes; non-adjacent hours split runs; two separate runs both returned; `new_runs` since-dedupe (equal start excluded, later start included).
- [ ] Implement → green → commit `feat: episode detection as dedupable runs (drop hourly liveness model)`.

---

### Task 4: Digest formatting

**Files:** `monitor.rb`, `test/monitor_test.rb`.

**Produces:**
- `Alerts.pretty_day('2026-07-03')` → `'Fri 3 Jul 2026'` (use `%a %-d %b %Y`).
- `Alerts.digest_title(from_day, to_day)` → `"Air quality digest — Hawcliffe Rd, Fri 3 Jul 2026"`, or `"… Mon 29 Jun 2026 to Fri 3 Jul 2026"` for ranges.
- `Alerts.digest_body(episodes, limit_titles, problems, day_means, aliases)`:
  - episodes: `[{species:, start:, last:, ongoing:, peak:, others_mean:}]` → `## Elevated vs other stations` bullets: `- **NO₂** 23 Jun 19:00–23 Jun 21:00: peak **235.6 µg/m³** vs 77.4 across the other stations (3.0×)`, ` (ongoing)` suffix when flagged;
  - limit_titles: strings from `Alerts.limit_title` → `## Over EU legal limits` bullets;
  - problems: strings → `## Data problems` bullets;
  - day_means `{day => {id => {'no2'=>f|nil,'pm25'=>f|nil}}}` + aliases `{id=>alias}` → per-day `## Daily means (µg/m³)` tables (`| Station | NO₂ | PM2.5 |`, `–` for nil);
  - omits empty sections; ends with portal link.
- [ ] Failing tests: title single + range; body contains episode bullet text, section headers only when non-empty, `–` for a nil mean, portal link.
- [ ] Implement → green → commit `feat: daily digest formatting`.

---

### Task 5: Monitor digest flow

**Files:** `monitor.rb`, `test/monitor_test.rb`.

**Produces:** `Monitor#run` = discover → registry → fetch (from `min(last_hour+1h, now − FETCH_MIN_HOURS)`) → `#digest`. `#digest(target, others)`:
1. `to_day = today − 1`; `from_day = last_digest_day + 1` (or `to_day`); clamp to `DIGEST_MAX_DAYS`; if `from_day > to_day` → log and return (still archived).
2. Window: from `from_day 00:00 − CONTEXT_HOURS` to last completed hour, via `Archive#window`.
3. Per species: plausible-filter target+comparators, `Rules.qualifying_hours`, `Episodes.new_runs(hours, qualifying, state[species]['since'])` → episode entries (peak hour = max target value in run; ongoing = run's last hour == newest window hour); update `since` to newest run start.
4. Limits: as before but `window_start` = window start hour; collect `Alerts.limit_title` strings (no separate issues).
5. Data problems (target only, per reported day): implausible readings filtered (count), or `< DAILY_MIN_HOURS` plausible values.
6. Day means for the context table (plausible-filtered).
7. `noteworthy = episodes | limit_titles | problems` any? → one issue via notifiers (skipped, printed in dry-run). Always: `last_digest_day = to_day`, state written after notify (not in dry-run). Diagnostic `puts` of counts.

`load_state` → `{ 'no2' => {'since'=>…}, 'pm25' => {…}, 'limits' => {…}, 'last_digest_day' => … }`, tolerating old files. CLI gains `migrate-columns`.

- [ ] Failing tests (rework MonitorTest; NOW = `Time.utc(2026, 6, 24, 6, 15)` so the spike day is "yesterday"):
  - spike fixture digest: exactly **one** notification; title `Air quality digest — Hawcliffe Rd, Tue 23 Jun 2026`; body has the NO₂ episode (peak 235.6), the limit section (`2nd exceedance this year, 18 permitted`), a data problem (fixture has only 11 of 24 hours), and a daily-means table row for Hawcliffe; state: `no2.since == '2026-06-23T18:00:00Z'`, `last_digest_day == '2026-06-23'`, `limits.no2.hourly.last_alerted == '2026-06-23T19:00:00Z'`.
  - same-day re-run: no second notification.
  - quiet fixture (all stations flat 10/3, full 24h day): no notification, but `last_digest_day` still advances.
  - dry-run: no notification, no state/stations files.
  - missing Hawcliffe still raises.
- [ ] Implement → full suite green → live `ruby monitor.rb run --dry-run` → commit `feat: daily noteworthy-only digest replaces hourly alerting`.

---

### Task 6: Migrate real data, workflow, README, ship

- [ ] `ruby monitor.rb migrate-columns` on the real repo; spot-check headers of all 6 CSVs + `grep 2026-06-23T19:00 history/2026.csv` unchanged values; commit `data: migrate history columns to readable slugs`.
- [ ] Workflow cron → `'15 6 * * *'` (comment: daily digest after the UTC day settles).
- [ ] README: cadence + digest description replaces hourly-alert wording; add **Data format** section (CSV layout, slug pinning, stations.json, µg/m³, UTC hours, raw values incl. implausible ones); note how to restore hourly alerting (cron + the git history of this change).
- [ ] Spec self-check against amendments; full suite; `ruby -c`; merge to fresh `main`; push.
