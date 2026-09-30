# 2.0 progress (overnight 2026-09-30)

Spec: artifact V99ewvN2VFmHxFZPXFc5gj v4 (local copy in the session scratchpad).
Branch: v2-liquid-glass (local only, never pushed).

## Tier 1
- [x] keySeconds column (v11) + sampler count; rollback to v1 verified (old build opens, reads, writes)
- [x] InterruptionClassifier (pass / peek / interruption, 60 s repeat merge) + tests
- [x] Classification off the main thread, cached per day and rule; focus blocks logged
- [x] Glass helpers (GlassStyle.swift)
- [x] Popover: 4 sections, icon footer, ⋯ menu with status, limits fold, first frame final, flyout axes
- [x] Today: 时间去了哪 with limits on the bars, ribbon to now with a dashed future, whole-minute 比昨天
- [x] Trends: every day labelled, today as 今天, axes trimmed, neutral heatmap; rules use checkboxes
- [x] Activities: two columns, read-only glass inspector, 修改分类… grows out (⌘E) with undo, lazy list for ranges
- [x] Ticks by the new rule, zoom slider (in the timeline card, see perf), TipKit tip, block context menu, VoiceOver counts
- [x] Settings › 记录与隐私 › 什么算打断 (15/30/60 s, typing toggle)
- [x] Menu bar: focus capsule with draining sand (variable draw on macOS 26), menus with icons
- [ ] Glass morph between hourglass and capsules: a status item shows only an image and text, so the capsule is an image, no morph
- [ ] Reduce Transparency / Increase Contrast / Reduce Motion captures: code paths exist, not captured (needs system settings)
- [x] Strings merged, check_strings green

## Tier 2
- [x] F3 回到刚才: capsule, popover button, ⋯ menu, ⌃⌥← (held only while offered), Settings toggle
- [x] F2 打断雷达 in Trends (today / 7 days, interruptions / all switches)
- [ ] Settings panes regrouped (通用/记录/智能/…): not done

## Tier 3
- [ ] F1 sessions, F4 离开补记, F5 recap, App Intents: not done

## Real-data interruption counts (15 s, dwell only)
9-24 42 · 9-25 38 · 9-28 33 · 9-29 14 (timeline thread: 30 / 46 / 21 / 12).
Unmerged visits: 62 / 63 / 49 / 19; single distracting window ≥15 s right after
a productive one: 25 / 28 / 16 / 9. At 30 s: 25 / 23 / 22 / 10; at 60 s: 11 / 11 / 11 / 6.

## Install
Installed 2026-09-30 01:56 from a clean `git archive` of the branch, Developer ID signed.
Backups: dist/backup/TimeSink-before-v2-20260930-0154.app and
timesink-before-v2-20260930-0154.sqlite; rollback: dist/backup/rollback-v2.sh.
Reinstalled 2026-09-30 03:37 from b1ba1c8 (F2 and F3 included), same signing;
the 2.0 build it replaced and a database copy are in dist/backup (…-0337).
rollback-v2.sh still puts back the pre-2.0 build.

## Performance (real-data copy, read-only, deleted afterwards; v1 = 24e2ecf)
Faster or level everywhere except the warm switch to Trends: the radar card adds
~25 ms to the longest frame (v1 ~127-141 ms, 2.0 ~147-162 ms over three
interleaved runs); the first frame after the click is ~50 ms in both. No single
part of the card carries it (canvas, rows, header and stats each bisected).
