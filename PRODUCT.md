# TimeSink

## Platform

macos

Native macOS 14+ application, built with SwiftUI and AppKit. This is a desktop product, not an iOS app or website.

## Users

Personal Mac users who want to understand where their time goes and reduce distraction.

## Product Purpose

Automatically record application and website activity, make a day understandable, and let people decide how to spend their next period of time.

The home screen should first answer where today's time went and what the day's rhythm looked like. Detailed rankings and heatmaps are secondary,.

## Operating Context

The user confirmed on 2026-09-23 that the menu bar should prioritize a quick view of current status and today's time, with deeper information in the main window.

## Capabilities and Constraints

- Existing native application and website tracking, editable classification rules, statistics, activities and timeline, time budgets, and focus sessions.
- Screenshot collection, optional cloud synchronization, and optional model-assisted classification have distinct controls. Do not claim that every feature is offline or that pausing screenshot collection pauses all activity tracking.
- `TimeSinkSpace` remains a separate experimental executable. The main app now exposes local screen/OCR review in the Activity inspector; missing or expired captures show an honest empty state.
- The 2026-09-28 user request selects the supplied Refined artifact for full replication: Today, Activity, Trends, Focus and budgets, Organization, seven settings tabs, onboarding and auxiliary surfaces. Earlier unselected concepts remain non-authoritative.
- Global tracking pause now closes the active segment, blocks application/title/URL sampling and screen collection, and preserves a real gap. The preference is persistent; exact restart deadline scheduling still needs B11 in the backend checklist.
- Chrome website sampling has a persistent Privacy control, separate from automation permission. Confirmed incognito windows are excluded; unknown privacy state suppresses titles, URLs and screenshots while app-level duration remains (B08).
- AI website suggestions require explicit acceptance. Native-app suggestions, unified cross-type ordering, device counts and browser restoration gaps are tracked in `docs/refined-backend-checklist.md`.

## Brand Commitments

The name is TimeSink. For the current work, the user explicitly requires replication of https://claude.ai/artifact/XPWfaofcbb8RNGDABCjmmK. Its exported `docs/reference/refined/design.html` is the visual authority. Use native SF/PingFang, real macOS controls and materials, the user’s system accent and the source’s adaptive category colors; preserve user-edited colors. Do not replace this world with an invented direction.

## Evidence on Hand

- Current SwiftUI/AppKit sources under `Sources/TimeSinkKit/UI/`.
- Current native synthetic-data renders under `docs/design-audit-images/refined/`, with a manifest at `docs/design-audit-images/refined/manifest.json`. The debug `--design-preview` runner uses an in-memory database and does not start tracking or cloud/model requests. These are not live-user screenshots.
- A signed native build was installed and restarted on 2026-09-28 with existing records preserved. Native previews do not verify every permission, notification, animation or cloud scenario. The subsequently integrated upstream localization and updater changes have not yet been installed.
- Validation and remaining backend work are recorded in `docs/refined-implementation.md` and `docs/refined-backend-checklist.md`. Captures use synthetic data and do not establish complete runtime certification.

## Product Principles

- Make today's recorded time and the recording state easy to understand.
- Keep the menu bar brief and route deliberate investigation to the main window.
- Preserve gaps in recorded time and distinguish classification-derived time from focus sessions.
- Show advanced analysis when requested rather than giving every metric equal prominence.
- Keep loading, empty, paused, and permission-related states honest and actionable.
