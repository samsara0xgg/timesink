# Screen capture tuning — 2026-09-21

Why the collector now checks every 10 s, reads text on small changes and on a
2-minute clock, and records its own health. Numbers below are what was
measured on this machine that evening; none of them is an all-day energy
figure.

## What was wrong with the fd039ff collector

- A window had to sit in front 3 s before its first look, then was looked at
  every 30 s. Anything that appeared and vanished between two looks was gone.
- A look became a new capture only when at least 10% of a 32×20 grayscale
  signature moved. One new chat line or one new terminal line moves about
  1–3% of the cells, so the row kept being extended with the old text
  indefinitely, however often the window was checked.
- Nothing recorded *why* a stretch had no captures: a denied permission, a
  failing screenshot, a failing OCR and a quiet window all looked the same.

## Data that set the parameters

From the live database, 2026-09-21 07:00Z–2026-09-22 07:00Z (Allen's local day):

| span length | spans | minutes |
|---|---|---|
| < 1 s | 239 | 3.9 |
| 1–2 s | 186 | 5.6 |
| 2–3 s | 150 | 6.1 |
| 3–5 s | 225 | 14.3 |
| 5–10 s | 222 | 26.4 |
| 10–30 s | 248 | 74.2 |
| 30 s–2 min | 132 | 133.4 |
| > 2 min | 31 | 107.2 |

Lowering the 3 s settle to 2 s would add ~150 looks a day for windows that
were in front 2–3 s (mostly Cmd-Tab pass-throughs), each a screenshot and
usually an OCR, for six minutes of a day's attention. Settle stays at 3 s.

689 captures that day; only 12 had the same text as the previous capture of
the same app, so duplicate rows were not the problem — missed changes were.

## Bench: before and after, 3 minutes each, real desktop

`tsprobe capture 180 30 legacy` reproduces fd039ff (30 s looks, OCR at
≥10% signature change, no refresh); `tsprobe capture 180 10` is the shipped
policy. Both watched whatever Allen had in front (Chrome, a resume document
being edited, WeChat); the two windows are different minutes, so row counts
compare workloads as much as policies. CPU is the probe process's own
`getrusage` time, including the first-OCR model warm-up (~2–3 s).

| | legacy 30 s | new 10 s |
|---|---|---|
| window switches seen | 11 | 6 |
| looks (checks) | 11 | 22 |
| OCR runs | 10 | 20 |
| rows inserted | 10 | 20 |
| rows extended without OCR (unchanged) | 0 | 1 |
| OCR ran, same text, extended (textSame) | 0 | 0 |
| screenshot failed / not front any more | 0 / 1 | 1 / 0 |
| images written | 1.9 MB | 2.6 MB |
| CPU | 5.89 s (3.3% of a core) | 9.93 s (5.5% of a core) |
| peak RSS | 182 MiB | 190 MiB |

Reading: the new policy looked twice as often and, because the document was
being typed into, almost every look found new text and stored it. That is
the intended behaviour and the worst case for cost: about 0.35–0.45 s of CPU
per OCR, one every ~9 s while content changes continuously, roughly 50 MB of
JPEG per hour of non-stop editing. On a static window the same policy costs
six screenshots a minute plus one OCR every two minutes, which the probe put
under 1% of a core (0.3 s/min of screenshots, 0.2 s/min of OCR).

## What changed

| parameter | before | after | where |
|---|---|---|---|
| first look after a window comes to front | 3 s | 3 s | `ScreenCapturePolicy.settleSeconds` |
| re-check interval | 30 s | 10 s | `ScreenCapturePolicy.checkInterval` |
| look after a title change in the same window | none | 1 s | `ScreenCapturePolicy.titleSettleSeconds` |
| new row on signature change | ≥ 10% | ≥ 10% | `ScreenSignature.changedFraction` |
| OCR to compare text on signature change | never | ≥ 2% | `ScreenSignature.ocrFraction` |
| forced re-read of unchanged-looking content | never | 120 s | `ScreenCollector.refreshInterval` |
| health record | none | one `captureHealth` row per 10 min and per interruption | `ScreenCollector.healthWindow` |
| image retention | 7 days | 7 days | `CaptureRetention.days` |

Decision logic per look: signature moved < 2% and last read < 120 s ago →
extend the row, no OCR. Otherwise OCR; if the signature moved < 10% and the
text is identical → extend the row and restart the refresh clock, no new
JPEG. Otherwise → new row with a new JPEG. Segments (window change, lock,
sleep, pause, stop, tick gap) are unchanged: a row is never extended across
them.

## Health counters

`captureHealth(windowStart, windowEnd, checks, unchanged, textSame, inserted,
extended, ocrRuns, ocrFailed, screenshotFailed, notFront, permissionDenied,
skippedBusy)`. A window closes every 600 s and on every interruption; empty
windows are not written. This is bounded by time and by interruptions, never
per tick.

## Not measured, not claimed

- All-day battery or energy impact. The 3-minute probes above are the only
  CPU numbers.
- Recall of screen content. The refresh clock bounds how long a small change
  can go unread (120 s on a quiet window); content that appears and vanishes
  inside one 10 s interval is still missed, and content under the first 3 s
  of a window is never looked at.
- Chat-contact detection. A WeChat title is "Weixin" for every chat, so a
  contact switch is found by the signature/text path, not by the title path.
