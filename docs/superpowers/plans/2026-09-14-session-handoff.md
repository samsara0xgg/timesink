# Session handoff — TimeSink performance work

Written 2026-09-14 when the working session was paused. Read this plus
`2026-09-07-timesink-optimization.md` (which carries the full measured history
and the ranked plan) and you have everything; no conversation context is needed.

## State of the tree

**All work is UNCOMMITTED on `main`.** 231 tests green (run three times, no
flake). A signed release build of this state is installed at
`/Applications/TimeSink.app`.

```
 M Sources/TimeSinkKit/App/AppModel.swift
 M Sources/TimeSinkKit/Categorization/CategoryResolver.swift
 M Sources/TimeSinkKit/Categorization/Classifier.swift
 M Sources/TimeSinkKit/Core/SpanStore.swift
 M Sources/TimeSinkKit/Tracking/ChromeSampler.swift
 M Sources/TimeSinkKit/Tracking/FocusSessionController.swift
 M Sources/TimeSinkKit/Tracking/TrackerEngine.swift
 M Sources/TimeSinkKit/Tracking/WindowSampler.swift
 M Sources/TimeSinkKit/UI/MenuBarDashboard.swift
 M Sources/TimeSinkKit/UI/PanelHost.swift
 M Sources/tsprobe/main.swift
 M Tests/TimeSinkKitTests/ClassifierTests.swift
 M Tests/TimeSinkKitTests/DatabaseTests.swift
 M Tests/TimeSinkKitTests/TrackerEngineTests.swift
?? Tests/TimeSinkKitTests/AppModelDailyPulsesTests.swift
```

**Biggest risk right now:** this is ~1,100 lines of unreviewed-by-the-user,
uncommitted work with no commit to fall back to. The user has not asked for a
commit and it has not been made. Offer one early.

## Build and test — the normal commands do NOT work on this machine

The Xcode license was never accepted, so every `xcrun`-wrapped command (`git`,
`swift build`, `swift test`, `swiftc`) fails. Do not run sudo. Call the
toolchain binaries directly:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
P=$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer
export SDKROOT=$P/SDKs/MacOSX.sdk
export DYLD_FRAMEWORK_PATH=$P/Library/Frameworks DYLD_LIBRARY_PATH=$P/usr/lib
TC=$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin

$TC/swift-build --build-tests
$P/Library/Xcode/Agents/xctest .build/out/Products/Debug/TimeSinkKitTests.xctest
```

Traps that have each cost real time already: `swift-build` without
`--build-tests` does not relink the .xctest bundle (a mutation check will
silently run the stale bundle and appear to pass); `swift-test` runs only
swift-testing here and reports "No matching test cases"; a release-mode
benchmark needs `-c release -Xswiftc -enable-testing` or `@testable import`
fails to resolve. `make bundle CERT="TimeSink Dev"` then
`cp -R dist/TimeSink.app /Applications/` installs. Plain `git` works once
`DEVELOPER_DIR` is exported.

## What shipped (details and numbers in the other doc)

1. Per-tuple memo in `CategoryResolver.categoryID(for:)`, cleared only by
   `refresh()`.
2. `CompiledURLRule` in `Classifier.swift` — URL rules no longer use ICU
   case-folding search per rule per span.
3. Task A: `SpanStore.dailyTupleTotals` + `AppModel.dailyPulses` — the 30-day
   streak lookback aggregates in SQL instead of materializing every span.
4. Task B: the 1s tick's AX read and Chrome Apple Event run off MainActor,
   with a `tickInFlight` skip guard and a `suspensionEpoch` change detector;
   `tick(now:)` deleted so the regression suite drives the shipping path.
5. The deferred hover drill-down revert was executed (`git checkout` of
   MenuBarDashboard/PanelHost + panel-only `prewarm()` re-added).

Net on the reported symptom: popover open went ~9.2s -> ~0.11s steady state.

## THE OPEN PROBLEM — pick up here

The user restarted the app and reports a **new, different** symptom:

> "切换 Tab 的时候，或者点击每个按钮的时候，都会有点卡"
> (switching tabs, or clicking any button, feels a bit laggy)

This is interaction latency inside the windows, not the popover path that was
fixed. A 60-second `sample(1)` of the live process was taken while the user
clicked around. Evidence, not speculation:

- Main thread is **96% idle**: 50,158 of 51,436 samples are `mach_msg2_trap`.
  Total busy time is ~1.28s out of 60s. **There is no long freeze.** Whatever
  the user feels is short and frequent, or lives in a path this window missed.
- Largest TimeSink frame: `closure #3 in StatsView.body.getter` at
  **`StatsView.swift:34`** = 346 samples. Line 34 is
  `.onChange(of: model.dataVersion) { stats.recompute(model:forceHeavy: false) }`
  — so Stats fully recomputes every ~1.5s (the `scheduleEngineDataChanged`
  debounce) whenever the tracker writes a span and a Stats view is open.
- Inside that: `Aggregator.split` = 240 samples, of which
  `Calendar.dateInterval(of:for:)` = **220**. So ~92% of `split` is one
  Foundation call. `stackedSeries` = 132, `profileByWeekday` = 83,
  `productivityProfileByWeekday` = 25, `profileByHourOfDay` = 17,
  `productivityProfileByHourOfDay` = 4 — six separate per-span `split` passes
  per recompute. The profile shows `dateInterval` reaching ICU locale lookups
  (`_LocaleICU.minimumDaysInFirstWeek`).
- Also on the main thread: `Permissions.chromeAutomationStatus(ask:)` = 108
  samples (synchronous TCC/XPC), `SpanStore.spans(overlapping:)` = 88
  (synchronous DB read on the main actor).

Raw profile was at `/tmp/ts_sample.txt` (temp, likely reaped — retake with
`sample <pid> 60 -file ...`).

### The fix that was about to be made, and not yet started

`Aggregator.split` (`Sources/TimeSinkKit/Stats/Aggregator.swift:90`) calls
`calendar.dateInterval(of: component, for: span.start)` once per span, and once
more per additional bucket the span crosses. Consecutive spans almost always
fall in the same bucket (~1,450 spans/day in a 30-day window, so a `.day`
bucket repeats ~1,450 times in a row; `.hour` ~60), so a **one-entry cache of
the last resolved interval** should eliminate nearly all of those calls.

Note this is the opposite of an earlier measured result and the distinction
matters: a one-entry cache in front of the *classification* memo was measured
useless (only 633 of 31,804 spans repeat the preceding classification tuple,
2%). Bucket locality is completely different — verify it rather than assuming,
but the profile already implies it.

Implementation care:
- `DateInterval.contains(_:)` is **inclusive of `end`**; bucket membership must
  be `date >= start && date < end`, or a timestamp exactly on a boundary lands
  in the wrong bucket.
- `split` is `public` and directly exercised by tests. Keep its signature and
  semantics; add the cache as an internal path the six aggregate callers use.
- `calendar.component(.hour/.weekday, from:)` per part is a second Calendar
  cost (`_CalendarGregorian.dateComponents` = 164 samples) — worth looking at
  in the same pass.
- Prove equivalence on real data, not just on a fixture, and mutation-check
  whatever test is added.

### The question that was never answered

**Which "Tab"?** Settings-window tabs (`AppModel.settingsTab`) and the main
window's Stats/Activities sidebar are different code paths with different
fixes. Ask before building the second half of this.

There is also a second, independent hypothesis the profile neither confirmed
nor ruled out, because it depends on the user clicking a Settings button during
the sample window: **11 call sites do `model.resolver.refresh()` immediately
followed by `model.dataChanged()`** (`SettingsPanes.swift` 324, 337, 486, 499,
601, 613, 705; plus `TitleRuleEditor.swift:241`, `ActivityListView.swift:200`,
`LLMClassifier.swift:127`). `refresh()` re-reads the 8k-row domain table **and
clears the new classification memo**; `dataChanged()` then clears the range
cache. So any settings edit drops the next computation to the cold path
(measured 618ms on the real database). Worth stating plainly to the user: the
memo did not make anything slower in absolute terms, but it turned uniformly
slow into fast-with-a-cliff, and a cliff is easier to perceive as "laggy".
`CategoryResolver.refresh()` should be split so a single-row edit stops
reloading everything — this is Batch 1b in the other doc, still not done.

## Still open from the plan, in priority order

1. The `Aggregator.split` Calendar cost above (now the top item, promoted by
   the profile).
2. Stop Stats recomputing every ~1.5s while the user is interacting —
   `StatsView.swift:34`'s `dataVersion` hook. Gate on window visibility or
   debounce it.
3. Split `CategoryResolver.refresh()` (Batch 1b) so a one-row edit does not
   wipe the memo and reload 8k rows.
4. `TitleRuleEditor` per-keystroke affected-preview scan, no debounce
   (`TitleRuleEditor.swift:135-138`, measured 53-62ms/keystroke).
5. `UncategorizedSettingsPane` recompute with no tab-visibility guard
   (`SettingsPanes.swift:657`).
6. Defer `AppModel.init()`'s synchronous `refreshMenu()` (`AppModel.swift:159`)
   — watch for a spurious launch-time budget notification when it moves.
7. Span fragmentation (37% of spans under 2s). Now a disk-growth item
   (~138MB/year projected), not a lag item.

## Two behavior changes the user should keep an eye on

- ChromeSampler's ScriptingBridge timeout went 60 ticks -> 15 (0.25s). Chrome
  replies in the 250ms–1s band now count as failures and feed `chromeBackoff`,
  so `chromeCaptureDegraded` may appear more often. Reverting is a one-line
  change to `ChromeSampler.timeoutTicks`.
- `frontmostApp()` has no test coverage — every test installs the
  `windowSampleProvider` seam and `tickAsync` skips the AppKit read when a seam
  is present. Not a regression (it was equally uncovered before), deliberately
  left.

## Corrections made during the work, so they are not re-derived

- An earlier claim that the popover path would degrade back to ~1.8s within a
  year was wrong, and is withdrawn: measured on a synthetic 540k-row/374-day
  fixture, `.last30` stays at ~168ms because it fetches 30 days, not the table.
- The classification memo's cap policy must be **clear-on-full**, not
  stop-inserting. Measured on that same fixture: no memo 39,714ms,
  clear-on-full 10,413ms, stop-inserting 27,446ms. Stop-inserting freezes the
  memo on the oldest tuples and throws away temporal locality. A prior attempt
  to "fix" the cap that way was a 2.6x regression.
- Task A's implementing agent reported a 5.8x warm speedup; independent
  re-measurement against a warm `rangeCache` baseline gave **3.2x**
  (135ms -> 43ms). Use the smaller number.
