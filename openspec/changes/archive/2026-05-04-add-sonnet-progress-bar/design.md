## Context

The claude.ai usage endpoint returns a `seven_day_sonnet` window alongside `five_hour` and `seven_day`. `Models.swift` already decodes it into `UsageResponse.sevenDaySonnet`, but `UsageResponse.allWindows` (which the popover iterates) **explicitly excludes it**:

> The Opus and Sonnet sub-windows are omitted — they are informational breakdowns of the 7-day total and do not represent independent rate limits the user can act on.

That comment was correct at the time, but Max-plan users on Sonnet 4.7 in practice care more about the Sonnet sub-bucket than the aggregated 7-day total — burning through Sonnet costs them access to their primary model. Showing the sub-bucket as a dedicated bar in the Usage tab is the smallest change that gives that signal.

## Goals / Non-Goals

**Goals:**
- A third progress bar in the Usage tab labelled "7-Day Sonnet" using the existing `UsageWindowView` rendering.
- A user-controlled toggle to hide the row (default on).
- Graceful fallback: row hidden if the API omits the field.

**Non-Goals:**
- No pace line or "outlook" line for Sonnet (it's not an independent rate-limit cycle).
- No reset-detection notification, no pace notification for Sonnet.
- No Sonnet entry in the menu bar window picker.
- No Sonnet entry in chart history (no new keys in `UsageDataPoint`).
- No equivalent Opus row.

## Decisions

### 1. Render via the existing `UsageWindowView`, not a new view

`UsageWindowView` already takes `title`, `window`, `paceRate`, `projectedHours`, `scale`, `paceRateUnit`, `isStale`. Pass `paceRate: nil`, `projectedHours: nil`, `isStale: false` (or compute `isWindowStale(window)` for consistency) — the view already draws nothing pace-related when both are nil. Title is `String(localized: "7-Day Sonnet")`.

**Rejected:** a stripped-down `SonnetWindowView`. Duplicates layout for no reason.

### 2. Iterate via a parallel accessor on `UsageResponse`, do not change `allWindows`

`allWindows` is currently typed `[(MenuBarWindow, UsageWindow)]` and powers both the popover and (transitively) the menu bar window picker. Adding Sonnet to it would force a new `MenuBarWindow.sevenDaySonnet` case which would then leak into `SettingsView`'s menu bar picker — exactly what we want to avoid.

Instead, leave `allWindows` alone (keeps menu bar picker untouched) and have `MenuBarView.usageWindows(_:)` render the existing `allWindows` rows then conditionally append a Sonnet row, sourced directly from `usage.sevenDaySonnet`.

**Rejected:** introducing a separate enum for "popover-only" windows. Overkill for a single addition.

### 3. Settings toggle: `showSonnetWindow: Bool`

New `@Published`-style `var showSonnetWindow: Bool` in `UsageViewModel`, persisted under `"showSonnetWindow"`, default `true`. Wired into `SettingsView`'s Display section using `GreenSwitchStyle()` (per global rule). Read at render time in `MenuBarView.usageWindows`.

**Rejected:** auto-detect "is this a Max plan" and hide for Pro/free. The API doesn't expose Sonnet for non-Max accounts anyway, so the bar simply won't render — auto-detection adds code with no user-visible win.

### 4. No reset detection, no pace machinery for Sonnet

Sonnet's `resetsAt` is the same as the parent 7-day window's `resetsAt`, so any reset notification on it would be redundant with the existing 7-day notification. Pace/projection requires a per-window `utilizationHistory` bucket which we don't want to add for a sub-window the user can't independently act on.

If, after shipping, Max users specifically ask for "tell me when I'll burn through Sonnet", that becomes a separate change.

### 5. Position: between 7-day and `extra_usage`

Visual order: 5-Hour → 7-Day → 7-Day Sonnet → Extra Usage. The Sonnet bar reads as a "drill-down" of the row above it.

## Risks / Trade-offs

- **API field could disappear for some plan tiers**: already handled — the row only renders when `usage.sevenDaySonnet != nil`.
- **A reader might wonder why Sonnet has no pace line when 5h/7d do** → Mitigation: it visually communicates the "this is informational" framing without needing a tooltip. If users complain, we can revisit in a follow-up change.
- **Toggle default is on**: surfaces the new bar to all existing users without action. Considered "off by default + opt-in", but the user explicitly asked for the bar — defaulting to on matches that intent.

## Migration Plan

No migration. New default is `showSonnetWindow = true`; existing installs see the bar on first launch of the new build.
