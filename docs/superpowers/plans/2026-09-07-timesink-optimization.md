# TimeSink Optimization Plan

> **Status as of 2026-09-14 (second session).** This document is the audit and
> the ranked plan; it is no longer a description of the tree. Several of its
> items have shipped and two of its recommendations turned out to be wrong.
> **Read `2026-09-14-session-handoff.md` first** for what is actually built,
> the measured numbers, and what is deliberately left open.
>
> Shipped since: Batch 0 items 1, 3 (title-rule debounce), 5 (tab-visibility
> guard, plus the same defect found in `RulesSettingsPane`); Batch 1 items a,
> b (as a `refreshCategories()` split, narrower than the `refreshRules()`
> sketch below), d.
>
> Two corrections to the plan below, both from measurement:
>
> - **Batch 0 item 4 is not safe as written.** Evicting only cache entries
>   with `interval.end >= Date()` leaves a stale entry when the tracker clamps
>   a span's end into an already-closed window after sleep/wake. See the
>   handoff doc for the safe version and why it was not built.
> - The audit did not identify `Aggregator.split`'s per-span
>   `Calendar.dateInterval` at all, which turned out to be the single largest
>   interactive cost (731 ms -> 95 ms per Stats recompute). No static lens
>   found it; a `sample` of the running process did.

Date: 2026-09-07. Read-only audit; nothing implemented. All `file:line` references were
produced by the audit and the load-bearing ones re-checked by hand against HEAD.

## 0. Evidence status

31 findings from 8 audit lenses, each put through an independent adversarial verifier
that re-read the code. Zero were refuted outright -- an unusually clean rate, so the
five load-bearing claims were re-verified by hand:

- `TrackerEngine.start()` schedules a 1s `Timer` whose body is `MainActor.assumeIsolated { tick() }` -- confirmed, `TrackerEngine.swift:251-256`.
- `WindowSampler.focusedWindowTitle` makes two synchronous `AXUIElementCopyAttributeValue` calls, each with a 0.25s messaging timeout -- confirmed, `WindowSampler.swift:18-31`.
- Classifier throughput of ~0.148ms/span comes from the codebase's own measurement (7394ms per 50k spans) -- confirmed, `Classifier.swift:18-23`.
- `AppModel.rangedSpans(for:)` runs `spanStore.spans(overlapping:)` + `resolver.categorized(...)` synchronously with no background hop -- confirmed, `AppModel.swift:258-283`.
- `TitleRuleEditor.affectedPreview` is a plain computed property calling `TitleRuleInput.affected(items: model.rangedSpans(), ...)`, re-evaluated on every body pass, no debounce -- confirmed, `TitleRuleEditor.swift:135-138`.

New evidence not in the audit, measured against the live database
(21434 spans, 2026-08-23 onward):

- **7923 spans (37%) are shorter than 2 seconds**, and **13472 (63%) are Chrome**.
  This independently corroborates the span-fragmentation finding (Batch 1c): the table
  is roughly 3x larger than genuine activity-switch volume warrants, and every one of
  those rows is re-classified on each wide-range cache miss.

## 0b. MEASURED, 2026-09-14 (supersedes the extrapolations below)

The audit had no wall-clock trace; it does now. Benchmarked in a release build
against a copy of the real database (31,804 spans by 2026-09-14 -- up from
21,434 a week earlier, ~1,480/day, so the lag was actively worsening).

| Path | Before | After Batch 0 |
|---|---|---|
| Full classify pass, no memo | 9,023-9,278 ms | 2,223 ms |
| First pass after launch / rule edit (memo cold) | -- | 576 ms |
| Every later pass (memo warm) | -- | 12 ms |
| SQL fetch + row decode of 31,804 rows | 97 ms | 97 ms |

So the reported symptom -- popover open forcing a 30-day lookback -- was
**~9.2 s of blocked main thread**, roughly 2x worse than Section 1's 3.17 s
estimate. It is now ~0.67 s on the first open after launch and ~0.11 s
thereafter.

Two findings from measurement that changed the plan:

- The dominant cost was never the row count. It was
  `Classifier.matches(pattern:in:)`'s `range(of:options: .caseInsensitive)`, an
  ICU case-folding search run once per URL rule per span (51 builtin rules).
  Measured over 2,381 distinct URLs x 51 patterns: 2,301 ms via ICU vs 538 ms
  via lowercased `contains`. `CompiledTitleRule` had already learned this for
  titles in Task 4; the URL scan had not.
- The span table's 31,804 rows carry only 4,005 distinct
  (bundleID, url, domain, title) tuples, ~8x redundancy, because a span is
  reopened on every window-title flicker. Memoizing per tuple in
  `CategoryResolver` removes that multiplier outright -- and note this also
  blunts Batch 1c (span fragmentation), which is now a data-hygiene and
  disk-growth item rather than a lag item.

An idea measurement killed: a one-entry "previous key" front cache ahead of the
memo. Only 633 of 31,804 spans repeat the immediately preceding tuple (2%), so
it would have bought nothing.

### Shipped in this pass

- `CategoryResolver`: per-tuple memo, cleared only by `refresh()`. Pinned by
  `testMemoIsInvalidatedByRefresh`, which was mutation-checked -- removing the
  invalidation makes it fail with the real symptom (a user's reassignment
  silently not taking effect).
- `Classifier`: new `CompiledURLRule` mirroring `CompiledTitleRule`; tiers 3
  and 5 use it with a once-per-call lowercased URL. Pinned by
  `testCompiledURLRuleAgreesWithMatches`, which caught a genuine semantic
  regression during development (an empty `re:` URL pattern matches every URL
  in the pure function; the F4 guard copied from the title path would have
  changed that). Behavior preserved verbatim -- this is a perf change only.
- Deleted the now-unused `Classifier.matches(_ rule:url:)` overload.
- 221 tests pass.

### Still open from Batch 0/1, in priority order

1. `AppModel.rangedSpans(for:)` still classifies on MainActor. With the memo
   warm this is ~110 ms rather than ~9 s, so backgrounding it (Batch 1d) drops
   from "the fix" to an optional polish item. Re-measure before building it.
2. Batch 0 items 1 (tick IPC off MainActor), 3 (`TitleRuleEditor` debounce),
   5 (`UncategorizedSettingsPane` visibility guard), 6 (defer `init`'s
   `refreshMenu`) are untouched and still stand on their own evidence.
3. Batch 0 item 4 (scoped cache eviction) is **downgraded**: `.last30`'s
   interval ends at `Date()`, so an end-timestamp-based eviction rule would
   never have spared it. It now only saves historical ranges, and the memo
   already makes those cheap. Do not build it as specified.


### Scaling check, 2026-09-14 (synthetic one-year fixture)

Extrapolation was wrong twice in this project, so the projection was measured
instead: the real 21.7 days of data replicated to 540,668 rows / 67,013
distinct tuples / 374 days (138 MB), matching the observed growth of 1,465
spans/day and distinct tuples at ~12.6% of rows.

| Path | rows | fetch | classify (warm) | total |
|---|---|---|---|---|
| `.last30` (what the popover asks for) | 43,709 | 149 ms | 16 ms | **168 ms** |
| all-time / multi-year `.custom` | 540,668 | 1,862 ms | 10,413 ms | **12,275 ms** |

So the popover path does **not** regress over a year -- `.last30` fetches 30
days, not the whole table. An earlier claim in this session that it would
return to ~1.8s was an extrapolation from an all-time query and is withdrawn.

The multi-year `.custom` range is the path that stays broken, and no cache
policy fixes it: baseline no-memo is 39,714 ms, the shipped clear-on-full memo
is 10,413 ms, and a stop-inserting-on-full variant measured 27,446 ms (it
freezes the memo on the oldest tuples and throws away the temporal locality
that makes the cache work at all). The ceiling there is the 1.9 s fetch plus
materializing 540k `Span` values, not the classifier.

## 0c. What is still architecturally unfixed

Batch 0 bought a constant factor (~85x on the reported symptom), not a change
in complexity class. Every cost below is still O(spans in range), evaluated
synchronously on MainActor:

1. **Aggregates are computed by materializing rows.** The popover's streak
   lookback pulls 43,709 `Span` values through Swift to produce 30 integers.
   `GROUP BY` in SQL, or a per-day rollup table written once per closed day,
   makes this O(days). This is the root cause of the popover path; the memo
   only made each row cheap. **Highest-value remaining work.**
2. **The 1s tick still blocks MainActor on synchronous IPC** -- two AX calls at
   0.25 s timeout each plus a 1 s-timeout Apple Event (`TrackerEngine.swift:251-256`,
   `WindowSampler.swift:18-31`, `ChromeSampler.swift:26-37`). Untouched by
   Batch 0, independent of it, and the remaining always-on jank source.
   Needs the reentrancy guard described in Batch 0 item 1.
3. **`dataChanged()` still wipes the whole range cache** (`AppModel.swift:222-227`),
   so the cache rarely survives live tracking. Cheap now; still the reason
   every popover open re-derives everything.
4. **`rangedSpans(for:)` still classifies on MainActor** (`AppModel.swift:258-283`).
   Worth doing after item 1, not before -- item 1 removes most of the work
   rather than moving it.
5. **Span fragmentation** -- 37% of spans are under 2 s. Now a disk-growth
   problem (138 MB/year projected) rather than a lag one.

## 0d. Batch 1 shipped, 2026-09-14 (Task A + Task B)

Both built in isolated worktrees, each independently reviewed, then merged and
re-verified in the main tree. 231 tests green, run three times for flake.

**Task A -- aggregate without materializing spans.** New
`SpanStore.dailyTupleTotals(dayBoundaries:)` groups the lookback window in
SQLite into one row per (day bucket, classification tuple); new
`AppModel.dailyPulses(days:endingAt:calendar:)` classifies each group once via
the existing memo and folds into per-day per-category seconds.
`TodayDashboardModel.refreshStreakIfDayChanged` uses it instead of
`rangedSpans(for: .last30)` + `Aggregator.dailyPulses`.

Measured by the parent session on the real database (31,853 spans), fair
cold-vs-cold and warm-vs-warm with separate resolver instances:

| | before | after |
|---|---|---|
| cold (first lookback after launch) | 831 ms | 618 ms |
| warm | 135 ms | 43 ms |

The 30 pulse values are bit-identical in both states. Note the implementing
agent reported 5.8x warm; the honest figure against a warm `rangeCache` baseline
is **3.2x** -- the larger number came from a baseline that re-paid the fetch.
Cold is only 1.3x because it is dominated by classifying ~5.3k distinct tuples,
which both paths do.

Design points worth keeping: day boundaries are computed in Swift with
`Calendar.current` and bound into the query, never by SQLite `date()` (UTC) or
`'localtime'` (DST-fragile); `end <= dayEnd` and `end > dayEnd` are exact
complements so every span is counted once; boundary-crossing spans come back
whole and are split in Swift against the same boundary array; all queries run
in one read transaction so the live tracker cannot insert mid-loop.

**Task B -- 1s tick off MainActor.** `WindowSampler`/`ChromeSampler` lost
`@MainActor`; the AX read and the Chrome Apple Event now run off-actor, with
only the state machine on MainActor. Main-actor stall per tick went from ~100%
of the IPC duration to ~0 (measured: 0.54s stall -> 0.001s, with the competing
main-actor task completing 1 turn vs ~33,000).

Three review findings were fixed in a second round:
1. The post-await staleness check was a state read (`isSuspended`), not a change
   detector -- a suspend->resume pair inside the IPC window slipped a stale
   sample through. Replaced with a `suspensionEpoch` counter bumped in
   `suspend`, `resume` and `stop`, captured before each await and compared
   after. The parent session verified this by mutation: neutering both guards
   turns 5 assertions across 4 tests red, including `rows[1].start` (ts(41) ->
   ts(40)), which proves the drop reaches `SpanBuilder` and not just
   `latestSample`.
2. `NSWorkspace.shared.frontmostApplication` had been moved off-actor as
   collateral. AppKit is now back behind `@MainActor func frontmostApp()`, with
   only `focusedWindowTitle(pid:)` -- the actual Mach IPC -- off-actor. Enforced
   by the Swift 6 compiler, not by comment.
3. The pre-existing regression suite was driving `tick(now:)`, a path production
   no longer ran, so the two orchestrations could drift silently. `tick(now:)`
   is deleted; all 19 legacy call sites moved to `await tickAsync(now:)` with no
   assertion changed.

Also: ChromeSampler's ScriptingBridge timeout is now `static let timeoutTicks =
15` (0.25s, matching the AX budget) with a test pinning the seconds value. This
is a real behavior change, not a pure perf one -- Chrome replies in the
250ms-1s band now count as failures and feed `chromeBackoff`. Watch for
`chromeCaptureDegraded` appearing more often in practice.

### Knowingly left open

- `frontmostApp()` has no test coverage: every test installs the
  `windowSampleProvider` seam, and `tickAsync` skips the AppKit read when a seam
  is present. Not a regression -- the read was equally uncovered before, when it
  lived inside `sample(at:)` -- so not worth a host-environment-dependent read
  on every test tick. Revisit if that function grows logic.
- Three async-tick tests rely on a single `await Task.yield()` reaching the
  child task before it parks. Failure mode is flake-red, never false-green.
  If it ever flakes, switch them to the spin-on-lock-flag pattern already used
  in `testSampleIsDroppedWhenSuspensionChangesDuringChromeFetch`.
- Blocking Mach IPC and Apple Events now run on Swift's cooperative thread
  pool, which is only acceptable because `tickInFlight` bounds it to one thread
  at a time. Both helpers carry a comment saying so. If that guard is ever
  removed, route these through a dedicated serial queue instead.

## 1. Why is it laggy

Two architecturally independent mechanisms are each confirmed high-severity. They are not equally weighted: mechanism B is corroborated by four lenses (db, render-dashboard x2, lifecycle) with a documented worst case of **3.17s**; mechanism A is corroborated by one lens (hotpath) with a worst case of **~0.5-1s**. Both are real; B is worse and better-evidenced.

### Proven — always-on, independent of any window being open

**A. TrackerEngine's 1s MainActor timer blocks on synchronous IPC.** `tick()` runs on `MainActor.assumeIsolated` every second (`TrackerEngine.swift:251-256`) and unconditionally calls `WindowSampler.sample()` (`TrackerEngine.swift:291`) — two synchronous `AXUIElementCopyAttributeValue` Mach IPC calls, 0.25s timeout each, worst case ~0.5s (`WindowSampler.swift:19-31`). Whenever Chrome's title changes, or at least every 5s, it also calls `ChromeSampler.activeTab()` inline (`TrackerEngine.swift:303-309`) — a synchronous Apple Event, 1s timeout (`ChromeSampler.swift:26-37`). Blocks the same thread driving the menu-bar UI, popover-open-or-not. Most consistent with *general* jankiness rather than lag confined to one view.

### Proven — every app launch

**A2. Menu-bar first paint is gated on a synchronous DB-open + full classify pass inside `App.init()`.** `TimeSinkApp.init()` (`TimeSinkApp.swift:21-162`, esp. 37-63) synchronously runs DB-open, `SeedImporter.importIfNeeded` (a per-row-INSERT loop over ~8,143 seed rows, only on a version bump), `CategoryResolver.refresh()` (5 sequential reads, `CategoryResolver.swift:39-64`), then `AppModel.init()` (`AppModel.swift:145-167`) unconditionally calls `refreshMenu()` (line 159) → `rangedSpans(.today())` (`AppModel.swift:201-220`). At the real data's "today" volume (1,535 spans), that's ~227ms of classify work (0.148ms/span x 1,535, per `Classifier.swift:18-23`'s own benchmark) — all before `MenuBarExtra` can render the icon. On a version-bump launch, the seed-import INSERT loop adds on top. This is a directly-felt "the icon takes a beat to appear, every single time I open the app" symptom.

### Proven — when Stats/Activities/Settings/the popover touch a wide date range (the more severe mechanism)

**B. Synchronous, un-backgrounded reclassification on MainActor, triggered too often.** `AppModel.rangedSpans(for:)` does a synchronous GRDB read plus a full per-span `Classifier.categoryID` pass entirely on MainActor, no background hop (`AppModel.swift:258-283`). At ~0.148ms/span (`Classifier.swift:18-23`) and 21,434 real spans spanning ~15 days, any range touching that whole window — most notably the built-in "近30天" — costs up to **~3.17s** of synchronous main-thread work on a cache miss. Five independent bugs force that cache miss more often than necessary:
- `AppModel.dataChanged()` wipes the *entire* `rangeCache` instead of just entries whose interval contains "now" (`AppModel.swift:222-227`).
- The popover's `.onAppear` forces an unconditional last-30-day fetch+classify on every open (`MenuBarDashboard.swift:713-720,762-771,173-195`), while `panelHost.prewarm()` two lines below is already deferred for exactly this reason.
- `CategoryResolver.refresh()` reloads the full ~8,222-row domain table on *any* single-row settings/rule edit (`CategoryResolver.swift:39-64`), even a lone title-rule toggle that never touched that table.
- `TitleRuleEditor`'s "affected" preview reruns an O(n) scan on *every keystroke*, zero debounce (`TitleRuleEditor.swift:135-138`) — independently benchmarked at ~53-62ms/pass, before the app's own classification cost. The single most directly reproducible instance: type in "新建标题规则…" with range = 近30天/本月, it visibly stutters per character.
- `UncategorizedSettingsPane` recomputes on every `dataVersion` bump with no tab-visibility guard (`SettingsPanes.swift:657`), once that tab has ever been opened in the session.

### Likely / real but not independently sufficient

- Chrome's title churn forces span close/reopen and a synchronous DB write roughly every 1.3s during ordinary browsing (`SpanBuilder.swift:12-19`, write path `TrackerEngine.swift:447-474`), inflating the span table ~3x beyond genuine activity-switch volume. Real waste, no write-latency measurement exists to call it a proven lag source.
- The popover's productivity ring resets to 0 and re-sweeps every ~30s heartbeat while open (`MenuBarDashboard.swift:762-771`) — cosmetic flicker, not a perf cost; the popover body is sub-millisecond to re-evaluate at this scale.
- The uncommitted hover-intent poll (16ms MainActor `NSEvent.mouseLocation`, up to 400ms) self-cancels within one sample on ordinary row-to-row travel; negligible absolute cost. Already covered by your own agreed, deferred 3-step revert (`hover-drill-revert-deferred.md`) — execute that, no new work here.

### Ruled out

- **The database/SQL layer is not the cause.** `EXPLAIN QUERY PLAN` confirms `span` queries use `span_on_end`; WAL (2.6-4MB) sits under its own 1000-page auto-checkpoint threshold; PRAGMAs are sane defaults; a full 21k-row scan is single-digit-to-low-tens of ms. Cost lives entirely in unthrottled Swift-side reclassification and synchronous IPC.
- `focusSession`'s missing end-index (`FocusSessionStore.swift:37-44`, `AppDatabase.swift:168-176`) is real but currently free — 1 row.

### Evidence gap, honestly stated

No Instruments/wall-clock trace exists anywhere in this audit — every magnitude above is a static-analysis extrapolation from the codebase's own benchmark comment or an independent micro-benchmark, not a measured hitch on a running instance. GRDB `DatabasePool` reader-pool sizing was also never checked by any lens (unverified assumption, low plausibility given work is already MainActor-serialized). Batch 0 ships the instrumentation to close the trace gap.

---

## 2. What's genuinely missing (ranked by value/effort)

None of items 4-8 are scheduled without your confirmation (Open Questions) — ranked here so a "yes" converts directly into Batch 3 work.

1. **Backup silently drops the most recent hours of activity** (S, high value — a data-loss bug wearing a feature-gap costume). No code ever calls `close()`/`checkpoint()`; AppKit's `.terminateNow` doesn't guarantee ARC teardown runs first. `AppDatabase.swift:6-10`, `TimeSinkApp.swift:361-371`, `README.md:49`.
2. **Failed LLM classification permanently blacklists a domain for the process lifetime**, silently (S). `LLMClassifier.swift:113-132`.
3. **No detection of revoked Accessibility permission** (S). Chrome has a full degraded-state badge; AX has nothing. `WindowSampler.swift:17-28`, `TimeSinkApp.swift:212-230`.
4. **No Shortcuts/CLI control surface** (S). `timesink://` scheme and `start`/`finish` already exist; only `/back` and `/allow` are wired. `TimeSinkApp.swift:382-399`.
5. **Budgets are ceiling-only — no floor/goal tracking** (M, new migration). `Records.swift:95-106`, `BudgetEngine.swift:9-15,34-39,110`.
6. **No data export** (S). Only path today is hand-copying the raw SQLite file.
7. **Drill-down hover panels have no keyboard/VoiceOver path** (S, low value — same data already reachable via each row's existing accessible Button + full window). `MenuBarDashboard.swift:403-493`, `PanelHost.swift:123-130`.
8. **No in-app diagnostics/version/DB-size row** (S, low value, pure convenience).

---

## 3. Sequenced work

### Batch 0 — kill the always-on stutter, the launch delay, and the worst per-keystroke freeze

| Item | Files/symbols | Expected improvement | Verification |
|---|---|---|---|
| 0. Signposts around tick's sample/chrome-fetch/write, ships first | `TrackerEngine.swift` (`import os` present) | Turns future reports into an Instruments-localizable trace; gives items 1 and Batch 1's backgrounding fix a real before/after number | One Instruments trace before items 1-6 ship, one after; compare named-interval durations. Does not gate items 1-6 (see rejection above). |
| 1. Background AX/Chrome IPC in `tick()`, with a reentrancy guard | Mark `WindowSampler.sample` (`WindowSampler.swift:19-31`) and `ChromeSampler.activeTab` (`ChromeSampler.swift:26-37`) `nonisolated`; restructure `tick()` (`TrackerEngine.swift:267-378,291,303-309`) to run them off-MainActor; cut `ChromeSampler.swift:30`'s `sb.timeout` 60→~15 ticks; add an in-flight guard so a slow tick's async work cannot overlap the next timer fire | Menu bar stops stalling up to ~0.5-1s whenever the frontmost app or Chrome is slow, independent of any UI being open; no possibility of two ticks concurrently mutating `SpanBuilder.current`/`chromeTabState`/`chromeBackoff` | **Automated, not manual QA**: `TrackerEngine` already exposes `windowSampleProvider`/`chromeTabProvider` injection seams (`TrackerEngine.swift:181-184`). Inject a provider that sleeps 2s, fire two Timer ticks back-to-back, assert the second tick does not run concurrently with the first and exactly one span write results (no duplicate/corrupted span). This is a hard requirement of the fix, not optional polish. |
| 2. Cache `idleThreshold` only (trimmed scope) | New `private var cachedIdleThreshold: Int` on `TrackerEngine`, refreshed on the existing 30s heartbeat instead of every 1s tick — no `SettingsStore` changes, no `Sendable` exception | Removes the uncached SQLite round-trip on every tick, including idle/locked | Count `SettingsStore.get` calls over a 5-minute idle period before/after; expect drop from ~300 to ~10 |
| 3. Debounce `TitleRuleEditor`'s affected-preview | `TitleRuleEditor.swift:135-138,186` → `.task(id:)` mirroring `ActivitiesView.swift:74`'s `CalendarTaskKey` idiom | Typing in "新建标题规则…" with range=近30天/本月 no longer costs ~53-62ms/keystroke | Simulate 10 keystrokes into `keywordText` with `model.range = .last30` on the real-scale fixture; assert `affected()` executes at most once per 150ms window, not once per character |
| 4. Scope `dataChanged()`'s cache eviction to "now" | `AppModel.swift:222-227` — evict only entries where `interval.end >= Date()` | Viewing a historical range while tracking continues no longer pays a forced re-fetch+reclassify on every engine write | Unit test: warm `rangeCache` with a historical interval and a "today" interval, call `dataChanged()`, assert the historical entry survives and "today" is evicted |
| 5. Guard `UncategorizedSettingsPane` recompute by tab visibility | `SettingsPanes.swift:657` + companion `.onChange(of: model.settingsTab)` | Editing a category/rule elsewhere no longer hitches an inactive 未分类 tab | Instrument `recompute()` with a call counter: open 未分类 once, switch to 通用, edit a category 5x, assert count==0 during those edits; switch back, assert exactly one refresh fires |
| 6. Defer `AppModel.init()`'s synchronous `refreshMenu()` | `AppModel.swift:159` → `Task { @MainActor [weak self] in self?.refreshMenu() }` | Icon appears immediately on launch instead of waiting out DB-open + resolver-rebuild + ~227ms classify | Signpost from `App.init()` entry to `MenuBarExtra`'s first body evaluation, before/after; expect ~227ms+ drop. **Check for side effect**: `budgetMonitor?.evaluate(...)` inside `refreshMenu()` now fires for real on its first (deferred) call rather than against a not-yet-assigned monitor — verify no spurious budget notification at launch. |

### Batch 1 — eliminate the wide-range freeze (frequency reduction + the actual fix, shipped together)

This is the fix for the single most severe, most corroborated mechanism in the audit. Items (a)-(c) only reduce how often it's hit; item (d) is the real fix and ships in this batch, not a trailing one.

| Item | Files/symbols | Expected improvement | Verification |
|---|---|---|---|
| a. Defer popover's forced last-30 streak fetch | `MenuBarDashboard.swift:713-720,762-771,173-195` — move into the existing deferred `Task { @MainActor in ... }` alongside `panelHost.prewarm()` | Opening the popover no longer synchronously pays a 30-day fetch+classify on every click | Signpost duration of `.onAppear`'s synchronous path before/after; expect the last-30 fetch+classify cost to disappear from it |
| b. Split `CategoryResolver.refresh()`; add in-place override mutators; bundle the 5→1 round-trip cleanup | `CategoryResolver.swift:39-64` → `refreshRules()` (urlRules+titleRules only) vs full `refresh()`; add `setDomainOverride`/`setAppOverride` for the `setUserDomain`/`setUserApp` call sites (`ActivityListView.swift`, `SettingsPanes.swift`); fold `CategoryStore.snapshot()` (5 reads → 1) into the same diff since it's the same file — don't let it inflate scope beyond that | A single domain/app/rule reassignment no longer reloads 8,222 rows | `writer.read` call counter during one title-rule toggle: expect 2 calls (urlRules+titleRules) not 5; 0 calls for `setUserDomain`/`setUserApp` (pure in-place mutation) |
| c. Scope Chrome's span-continuation title bypass to URL-bearing samples only | `SpanBuilder.swift:12-19` — bypass title-equality only when both samples carry non-nil `url`; refresh `cur.title` on merge; do not drop the title check for url-less apps (Finder/editors/terminals need it as their only boundary) | Chrome tab-title flicker stops fragmenting spans into ~1.3s pieces; span growth returns to genuine activity-switch volume | `SELECT COUNT(*), AVG(duration) FROM span WHERE appBundleID='com.google.Chrome' AND start > <session start>` before/after a comparable browsing session — average duration up, sub-2s count down |
| d. Background the classify itself | `AppModel.swift:258-283` — add `CategoryResolver.classificationContext` snapshot getter; on cache miss, capture context on MainActor, then run `SpanStore.spans(overlapping:)` + `Classifier.categoryID(...,context:)` (the plain `nonisolated` static func, **not** `resolver.categorized`, which is MainActor-bound) inside `Task.detached`; hop back to MainActor only to write `rangeCache`/`cacheOrder`/`dataVersion` | Selecting 近30天/本月 during live tracking, or any remaining cache miss, no longer freezes the UI thread — a brief stale-data flash is acceptable, a freeze is not | Force a cache miss on `.last30` while a mock MainActor counter increments every 10ms; assert the counter keeps incrementing (proves MainActor wasn't blocked) while the fetch+classify completes in the background. Plus `swift build` under strict concurrency as a compile-time actor-isolation check. |
| e. *(optional polish, rides along)* Ring stops resetting to 0 every heartbeat | `MenuBarDashboard.swift:762-771` — `guard target != gaugeProgress else { return }`, drop `gaugeProgress = 0` | Ring stops visibly deflating/resweeping while popover sits open | Signpost/frame check: ring only animates when `target` actually changes |

### Batch 2 — robustness / data-safety (cheap, ship opportunistically)

| Item | Files/symbols | Expected improvement | Verification |
|---|---|---|---|
| "导出备份…" via GRDB online backup | New Settings action, `try pool.backup(to: DatabaseQueue(path:))` via `NSSavePanel`; update README | Backup no longer silently drops un-checkpointed activity | Export while WAL has pending writes; diff row count against live `SELECT COUNT(*) FROM span` |
| Un-blacklist a domain after failed LLM classification | `LLMClassifier.swift:113-132` — add `attemptedDomains.remove(domain)` at the top of `catch`; keep the pre-`Task` `insert` to avoid a concurrent-dispatch race | A transient failure no longer permanently blocks reclassification | Point at an invalid API key, visit a new domain (fails), fix the key, revisit, confirm it retries |
| Detect revoked Accessibility permission | Mirror `chromeDegraded` plumbing (`TrackerEngine.swift`, `AppModel.swift:66-72,212`, `TimeSinkApp.swift:212-230`) with a direct per-tick `Permissions.accessibilityGranted(prompt:false)` check — no throttle needed, it's a local TCC-cache read | Revoking AX mid-session shows a menu-bar badge instead of silent degradation | Revoke Accessibility in System Settings mid-session; confirm badge/`accessibilityLabel` changes within ~1s |
| Add `focusSession_on_end` index | New migration mirroring `span_on_end` (`AppDatabase.swift:125-138` pattern) | Closes a latent (currently free) regression before `focusSession` accumulates history | `EXPLAIN QUERY PLAN` on `FocusSessionStore.sessions(overlapping:)` shows both indexes considered |

### Batch 3 — feature work

**3a — cheap, low risk, ship without waiting for confirmation:**

| Item | Files/symbols | Verification |
|---|---|---|
| `/start` + `/stop` in URL scheme | `TimeSinkApp.swift:382-399`, reusing `FocusSessionController.start(minutes:)` (throws — needs `try?`/do-catch) / `.finish(completed:)` | `open timesink://focus/start?minutes=25`; assert a focus session actually becomes active, not just that the handler didn't crash |
| CSV export | `DateRangeSelection` input → `SpanStore.spans(overlapping:)` + `CategoryResolver.categorized(_:)` → `NSSavePanel` → CSV writer | Export a known range, reopen the CSV, assert row count matches `SELECT COUNT(*) FROM span WHERE <range>`; spot-check 3 rows' category against live categorization |
| Keyboard/VoiceOver route for drill-down rows | `.accessibilityAction { expandedDrill = kind }` in `DrillDownModifier` (`MenuBarDashboard.swift`), routing to the existing `ExpandedDrillView` — **not** `attemptShow()`'s `NSPanel`, which is `.nonactivatingPanel` and never becomes key | VoiceOver: Tab to a drill-down row, activate via VO, assert `ExpandedDrillView` appears (not the floating panel) |
| Diagnostics row | One `Text` row in an existing pane: `Bundle.main` version + `Span.fetchCount(db)` + `FileManager` sizes on .sqlite/-wal | Assert displayed span count matches `SELECT COUNT(*) FROM span` |

**3b — needs your explicit sign-off before starting (M effort, new migration, real product-scope decision):**

| Item | Files/symbols |
|---|---|
| Budget floor/goal | New migration (v5) adding `kind` column to `budget` (default max) — bundle `focusSession_on_end` into this migration if it ships; `BudgetEngine.goalMet(spent:target:)`; new `BudgetSettingsPane.swift` section reusing existing row UI, comparison inverted for `kind==min`; new branch in `BudgetMonitor.evaluate` |

No verification defined yet — deliberately; this is not committed work until you confirm you want it.

---

## 4. Deliberately not doing

- **`tsprobe`'s unthrottled Chrome polling** — confined to a developer debug binary, zero shipped-app impact. Skip.
- **`Span`/`DomainCategoryRow` custom `init(row:)` decode optimization** — real but purely compounding on top of the classify path Batch 1 already backgrounds. Skip; revisit only if post-Batch-1 profiling still shows decode cost material.
- **WAL PRAGMA/checkpoint tuning as a standalone item** — directly disproven as a current lag cause. The real underlying concern (don't lose data on quit) is solved by Batch 2's export, not by threading a DB reference into `TrackerEngine.stop()` for a checkpoint-on-terminate hack.
- **Retention/pruning/VACUUM** — real (~150MB/year) but no measured performance impact and no disk-space complaint. M effort for a non-problem today. If ever built: manual/opt-in only, never auto-wired into startup like `pruneAlerts` — span rows are core historical data, not disposable dedup rows.
- **Category-filter-chip full-pipeline rerun** — downgraded to low severity on verification; a single in-memory dict pass the app already pays elsewhere by design. Not worth the diff.
- **Hover-intent poll loop** — no new work. Already covered by your agreed, deferred 3-step revert (`hover-drill-revert-deferred.md`). Execute that; don't duplicate with a separate fix.

## 5. Open questions

1. **Retention/pruning scope.** Want a manual "delete data older than N days" control given current growth is modest and unmeasured as a perf problem? Recommendation: skip for now.
2. **Backup automation scope.** Is a manual "Export Backup…" button (Batch 2) sufficient, or do you also want automatic periodic backup? Recommendation: manual only — automatic adds scheduling/rotation complexity for a problem manual export already solves.
3. **Which "功能还不够全面" gaps did you actually mean?** Batch 3a items are cheap enough to ship without asking; Batch 3b (budget floor/goal) needs your go-ahead before a migration-touching feature starts, given it's a guess sourced from competitive comparison (Rize/RescueTime), not something you named.
4. **Worth one targeted pass on `ChromeBlocker.swift`'s synchronous site-block redirect** (same synchronous-ScriptingBridge-on-MainActor shape as `ChromeSampler`, unexamined by any lens, adjacent to recent "redirect cooldown"/"focus block day clipping" commits)? Not confirmed as a lag cause — flagging because it's the one unexamined synchronous-IPC call site in the entire audit.
