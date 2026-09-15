# Session handoff — TimeSink performance work

Rewritten 2026-09-14, second session. Read this plus
`2026-09-07-timesink-optimization.md` (full measured history and the ranked
plan) and you have everything; no conversation context is needed.

## State of the tree

**Everything is committed on `main`.** 235 tests green. Working tree clean.

```
b6c7318  the previous session's ~1,100 uncommitted lines (memo, CompiledURLRule,
         SQL day totals, off-MainActor tick) -- committed as the rollback point
35ac648  Aggregator bucket cache                     731ms -> 95ms
d636158  both tab-switch paths
cdab412  metadata edits stop wiping the memo         611ms -> 0.04ms
4d68f4c  title-rule debounce + permission probe
65d1c6a  review round 1 fixes
```

A signed build of this state is at `dist/TimeSink.app`. **It is not
installed.** `/Applications/TimeSink.app` is still the `b6c7318` build.
Installing replaces the user's running tracker, so it needs their say-so:

```sh
make install CERT="TimeSink Dev"      # quits nothing -- kill the running app first
```

## Build and test — the normal commands do NOT work on this machine

The Xcode licence was never accepted, so every `xcrun`-wrapped command
(`git`, `swift build`, `swift test`, `swiftc`) fails. Do not run sudo. Export
`DEVELOPER_DIR` and call the toolchain binaries directly:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
P=$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer
export SDKROOT=$P/SDKs/MacOSX.sdk
export DYLD_FRAMEWORK_PATH=$P/Library/Frameworks DYLD_LIBRARY_PATH=$P/usr/lib
TC=$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin

$TC/swift-build --build-tests
$P/Library/Xcode/Agents/xctest .build/out/Products/Debug/TimeSinkKitTests.xctest
```

With `DEVELOPER_DIR` exported, plain `git` and `make bundle` both work (make's
`swift build` resolves through to `swift-build`).

Traps that have each cost real time: `swift-build` without `--build-tests`
does not relink the .xctest bundle, so a mutation check silently runs the
stale bundle and appears to pass — **this bit again this session**, always
confirm "Build complete" before trusting a test result; `swift-test` runs only
swift-testing here and reports "No matching test cases"; a release-mode
benchmark needs `-c release -Xswiftc -enable-testing` or `@testable import`
fails to resolve.

### Standalone benchmark harness

Measuring against the real database needs a binary linked to the release
products. This worked and is worth reusing:

```sh
R=$PWD/.build/out/Products/Release
$TC/swiftc -O -I "$R" -I "$PWD/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  -L "$R" bench.swift "$R/TimeSinkKit.o" "$R/GRDB.o" -lsqlite3 \
  -framework ScriptingBridge -framework ApplicationServices -framework EventKit \
  -o bench
```

Two gotchas: `import GRDB` needs that second `-I` or it fails with "missing
required module 'GRDBSQLite'" — or skip the import entirely and open the
database through `AppDatabase.open(at:)`, whose GRDB return type never has to
be named. And do not use `(label as NSString).utf8String!` with
`String(format: "%s")`: the pointer is dead before the format call and it
segfaults (it survived by luck in one binary and crashed in the next).

Copy the live database rather than opening it under the running app:
`~/Library/Application Support/TimeSink/timesink.sqlite` (plus `-wal`,
`-shm`). Table is `span`, not `spans`. 32,128 rows as of 2026-09-14, all of
them inside the last 30 days, so `.last30` is effectively a full-table scan.

## What this session did

### 1. Aggregator bucket cache (`35ac648`) — the big one

`Aggregator.split` asked `Calendar.dateInterval(of:for:)` for a bucket once
per span. Release build, 32,128 real spans:

| component | per call | one-entry cache |
|---|---|---|
| `.hour` | 7.6 ms | 5.8 ms |
| `.day` | 100.6 ms | 5.9 ms |
| `.weekOfYear` | 248.2 ms | 5.8 ms |

`.weekOfYear` is worst because it reaches ICU for `firstWeekday` and
`minimumDaysInFirstWeek` — which is exactly the
`_LocaleICU.minimumDaysInFirstWeek` frame the previous session's profile saw.
`.hour` was already nearly arithmetic, which is the opposite of what the
profile's `split` totals suggested.

`BucketSplitter` holds the last interval Calendar returned; the seven array
callers hold one per pass. End to end, `StatsModel.recompute(forceHeavy:true)`
at a 30-day range:

```
light path (6 passes)   605.88 ms ->  68.48 ms
heavy path (2 passes)   125.12 ms ->  26.65 ms
total                   731.00 ms ->  95.12 ms
```

**Two things measurement changed, worth not re-deriving:**

- The first cache attempt hit 14 times out of 64,026 lookups. The loop
  resolved the *next* bucket at the end of every iteration and let
  `while interval.start < span.end` reject it — doubling the Calendar calls
  for the ~99% of spans that fit in one bucket, and evicting the cache entry
  the next span was about to hit. Breaking before the lookup is what makes the
  cache land at all.
- Bucket locality had to be measured, not assumed. The previous session
  measured a one-entry cache *in front of the classification memo* useless (2%
  of spans repeat the preceding tuple). Bucket locality is unrelated: of
  32,127 consecutive pairs, 32,105 (99.93%) share a calendar day and 31,813
  (99.02%) share an hour.

### 2. Both tab-switch paths (`d636158`)

They are genuinely different code, and the user confirmed both felt laggy.

- **Sidebar.** `MainWindowView.detailContent` is a `switch`, so its branches
  are different concrete View types and SwiftUI tears the inactive one down.
  `StatsView` owned `StatsModel` in `@State`, so every 统计/活动 switch built
  a fresh one, resetting `lastHeavyDay`, and `onAppear` passed
  `forceHeavy: true` — a full 30-day lookback per switch. The model moved to
  `MainWindowView`, which a sidebar change does not tear down.
- **Settings.** `TabView` keeps every visited pane mounted, so a pane's
  `.onChange(of: model.dataVersion)` keeps firing for edits made on other
  tabs. `UncategorizedSettingsPane` re-ran a 30-day read plus per-span
  classification off screen. `RulesSettingsPane` has the identical defect —
  found while tracing, never previously reported. Both now record staleness
  and do the work only when selected.

### 3. Metadata edits stop wiping the memo (`cdab412`)

The counter-intuitive result of the session. `refresh()` itself is cheap; the
memo wipe is not:

```
refresh(), all 5 tables ................  12.11 ms
allCategories() alone ..................   0.04 ms
categorized(30d), memo warm ............  14.52 ms
categorized(30d) right after refresh ... 611.18 ms
```

Changing a category's colour did not cost 12 ms, it cost ~600 ms on whichever
view recomputed next — a 42x cliff. `refreshCategories()` reloads
`categoriesByID` only; `categoryMetadataChanged()` keeps `rangeCache` (whose
entries are span + categoryID, neither of which such an edit changes). The
other nine `resolver.refresh()` call sites edit domain assignments and rules,
which do change classification, and are untouched.

### 4. Title-rule debounce, permission probe (`4d68f4c`, `65d1c6a`)

`TitleRuleEditor.affectedPreview` was a computed property read from `body`, so
every keystroke re-scanned the range (53–62 ms/pass). Now `@State` behind a
250 ms trailing debounce. `GeneralSettingsPane`'s four permission probes —
one of which is a synchronous `AEDeterminePermissionToAutomateTarget` — run
once per activation instead of once per `onAppear`, gated on 通用 being the
selected tab.

### 5. Review round 1 (`65d1c6a`)

An adversarial review of the five commits confirmed two defects.

- **`forceHeavy` became dead.** Hoisting `StatsModel` removed an accidental
  escape hatch: the per-switch rebuild used to force a fresh 30-day lookback.
  With the model persisted and every call site passing `false`, the trend and
  heatmap only refreshed on a day rollover — so after reassigning spans or
  editing a rule they showed pre-edit numbers until midnight.
  `AppModel.dataEditVersion` now separates user edits from the engine's ~1.5s
  writes, and `recomputeHeavyIfNeeded` compares it alongside `lastHeavyDay`.
- **The permission probe was not tab-gated**, unlike its two sibling panes, so
  every Cmd-Tab back into the app re-ran the Chrome round-trip for a pane
  nobody was looking at.

A third finding (`MainWindowView`'s `@State` not surviving Cmd-W) was refuted:
the comment's claim is scoped to sidebar selection, and a rebuild on window
reopen is strictly rarer than the per-tab-switch rebuild it replaced.

The bucket cache and the `refreshCategories()` split each got their own
adversarial lens and came back clean.

## Corrections made during the work, so they are not re-derived

- `.hour` is the CHEAPEST calendar component to resolve, not the most
  expensive; `.weekOfYear` is ~33x worse than `.hour`. Reading the profile's
  `split` totals without separating components points the wrong way.
- A differential test (cached path vs `Aggregator.split`) cannot catch a bug
  in logic the two paths SHARE. Dropping the cache's upper bound left both
  returning `[]` and the differential test passed; the pre-existing absolute
  assertions caught it. Both kinds are needed.
- `>` vs `>=` in the loop's break condition is semantically equivalent (a span
  ending exactly on a boundary just yields an extra zero-second part that is
  discarded), so it is a useless mutation to test with. The two mutations that
  do bite are inclusive containment and a missing upper bound.
- Making the containment test inclusive of `end` does not produce wrong
  numbers, it produces an infinite loop that hangs the main actor. The loop's
  termination invariant (`next.start > bucket.start`) is now stated explicitly
  for that reason.

## Still open, in priority order

1. **`split` allocates an array per span.** 32k small heap allocations per
   pass, 8 passes per recompute. A callback form (`forEachPart`) would remove
   them. This is the largest remaining item in the 95 ms — but the allocation
   attribution is inferred from what is left after the Calendar cost went
   away, **not measured**. Measure before building.
2. **`dataChanged()` wipes the whole `rangeCache` every ~1.5s while
   tracking**, so nearly every recompute during active tracking is a cache
   miss (~97 ms fetch + ~14 ms warm-memo classify). Plan item Batch 0.4 says
   to evict only entries with `interval.end >= Date()`. **That rule is not
   safe as written**: after a sleep/wake the tracker can clamp a span's end
   into a window that has already closed, leaving a stale cached entry. The
   safe version is to have `engine.onChange` carry the earliest timestamp it
   touched and evict any entry overlapping it — a signature change across
   `TrackerEngine` and its tests. Designed, not built; worth doing only if
   wide-range tracking still feels slow after the above.
3. `calendar.component(.hour/.weekday)` per part: measured at ~1.2 ms/pass by
   subtracting `stackedSeries(.day)` (10.59 ms, no component call) from
   `profileByWeekday` (11.75 ms). **Not worth optimizing** — this closes the
   question, do not re-open it. It also cannot be replaced by arithmetic: DST
   fall-back repeats a wall-clock hour across two distinct `bucketStart`s.
4. `UncategorizedSettingsPane.recompute()` bypasses `rangeCache` entirely and
   calls `spanStore.spans(overlapping:)` directly (`SettingsPanes.swift:713`).
   Now that it is tab-gated this is much rarer, but it is still a redundant
   30-day read.
5. Defer `AppModel.init()`'s synchronous `refreshMenu()` (`AppModel.swift`) —
   plan item Batch 0.6. Watch for a spurious launch-time budget notification
   when it moves.
6. Span fragmentation (37% of spans under 2s). A disk-growth item
   (~138 MB/year projected), not a lag item.

## Two behaviour changes the user should keep an eye on

- ChromeSampler's ScriptingBridge timeout went 60 ticks -> 15 (0.25s) in
  `b6c7318`. Chrome replies in the 250ms–1s band now count as failures and
  feed `chromeBackoff`, so `chromeCaptureDegraded` may appear more often.
  Reverting is one line (`ChromeSampler.timeoutTicks`).
- The 30-day trend and heatmap now refresh on a day rollover or a user edit,
  not on every switch into 统计. If they ever look stale after something that
  should have changed them, the thing to check is whether that path bumps
  `dataEditVersion`.

## Not verified

None of the SwiftUI lifecycle changes (sidebar hoist, settings tab gating,
permission probe, title-rule debounce) have test coverage — they are view
lifecycle behaviour, not logic the suite can drive. They were verified by
build + the full suite staying green and by adversarial code review, **not by
running the app**. `dist/TimeSink.app` is built and signed and waiting for
someone to install it and click around.
