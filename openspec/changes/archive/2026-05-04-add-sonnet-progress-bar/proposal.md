## Why

The `/api/organizations/{id}/usage` response includes a `seven_day_sonnet` window that the app already decodes into `UsageResponse.sevenDaySonnet`, but it is **explicitly excluded from the popover** (`allWindows` only emits the 5-hour and 7-day totals). For Max users on `claude-sonnet-4-7`, knowing how much of the Sonnet sub-limit is consumed is more actionable than the aggregated 7-day total — they want to see how close they are to losing access to Sonnet specifically.

## What Changes

- Show a third progress bar in the popover's Usage tab labelled **"7-Day Sonnet"**, between the existing "7-Day Window" row and any `extra_usage` block. It uses the same `UsageWindowView` rendering as the other windows (title, percentage, progress bar, reset countdown).
- The Sonnet row is **display-only** — no pace line, no "outlook" line, no reset/pace notifications, no menu bar tracking option. Sonnet is a sub-window of the 7-day total, not an independent rate-limit cycle the user needs to actively manage outside of the existing 7-day signals.
- Add a Settings toggle **"Show Sonnet usage"** (default **on**) so users who don't care about the breakdown can hide the row.
- Hide the Sonnet row automatically when `seven_day_sonnet` is missing from the API response (e.g., free-tier accounts or any future API change).

Non-goals:
- No equivalent Opus row in this change. Opus is already deprecated for most subscription tiers and adds visual clutter for the majority of users. Can be revisited if requested.
- No changes to charts, pace, notifications, menu bar label, or polling interval.

## Capabilities

### New Capabilities

- `sonnet-window-display`: Rendering the Sonnet 7-day usage window as a third progress bar in the popover, with a Settings toggle and graceful fallback when the API omits the window.

### Modified Capabilities

(None — no specs exist yet.)

## Impact

- **Code**:
  - `Models.swift` — extend `UsageResponse.allWindows` (or add a parallel accessor) so the Sonnet window is iterable; add a new `MenuBarWindow` case **only if needed for stable iteration** (note: keep it out of the menu bar picker — it would dilute the existing 5-hour / 7-day choice).
  - `MenuBarView.swift` — `usageWindows(_:)` renders the Sonnet row when present and the toggle is on.
  - `UsageViewModel.swift` — new persisted toggle `showSonnetWindow: Bool` (default `true`), stored under `"showSonnetWindow"`.
  - `SettingsView.swift` — add the toggle in the Display section, using `GreenSwitchStyle()`.
  - `Localizable.xcstrings` — add `"7-Day Sonnet"` and `"Show Sonnet usage"` strings (English + Spanish).
- **No new persistence keys beyond the toggle**, no new dependencies, no API changes (response field is already decoded).
- **No migration needed** — the toggle defaults to on, matching the user's expressed wish.
