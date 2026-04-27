# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

ClaudeTracker — a macOS menu bar app that monitors Claude AI usage limits in real time. It polls the unofficial claude.ai web API and displays utilization percentages and reset countdowns. Open source, MIT licensed.

## Build & Deploy

Use the Makefile. Full clean cycle is required for every change (macOS caches stale binaries otherwise):

```bash
make build   # clean + build Release into release/build/
```

Then install:

```bash
cd release/dist && bash install.command
# or manually:
cp -R release/build/ClaudeTracker.app /Applications/
open /Applications/ClaudeTracker.app
```

Never `cp -R` over an existing `/Applications/ClaudeTracker.app` — Launch Services caches the old binary. Always delete first, then copy. `install.command` does this automatically.

Other Makefile targets:

| Target | Purpose |
|---|---|
| `make build` | Clean + build Release into `release/build/` |
| `make release` | `make build` + zip into `release/ClaudeTracker.zip` |
| `make tag VERSION=x.y.z` | Bump `MARKETING_VERSION`, commit, tag, push — triggers CI release |
| `make clean` | Remove all build artifacts |

Requires macOS 14+ (Sonoma) and Xcode 15+. No external dependencies.

## Releases

Cutting a release:

```bash
make tag VERSION=1.2.0
```

This requires a clean working directory. It bumps `MARKETING_VERSION` in `ClaudeTracker.xcodeproj/project.pbxproj`, commits the bump, creates an annotated git tag, and pushes both the commit and the tag. The GitHub Actions release workflow (`.github/workflows/release.yml`) triggers on the tag and publishes a GitHub Release with the zip attached.

The build uses `SIGNING_FLAGS="CODE_SIGNING_ALLOWED=NO"` and `SWIFT_STRICT_CONCURRENCY=minimal` on CI (both set in the Makefile). Do not remove `SWIFT_STRICT_CONCURRENCY=minimal` — Xcode 16 on `macos-15` treats some concurrency patterns as errors without it.

## Architecture

- **ClaudeTrackerApp.swift** — App entry point using `MenuBarExtra` with `.window` style (no dock icon via `LSUIElement`). The label uses a single `Image(nsImage:)` with a composed NSImage.
- **ClaudeAPIService.swift** — Networking via a hidden `WKWebView` that calls `fetch()` through `callAsyncJavaScript`. This bypasses Cloudflare bot protection which blocks plain `URLSession` requests. Also handles login flow (loads claude.ai login page, polls cookies for `sessionKey`). Uses `.defaultClient` content world.
- **UsageViewModel.swift** — Central state. Manages polling (Combine `Timer.publish`), persistence (`UserDefaults`), rate-limit backoff, session state, and notification dispatch. Generates the composed `menuBarImage` (SF Symbol + text baked into one `NSImage`); the icon color is `systemGreen` (0–49%), `systemOrange` (50–79%), `systemRed` (80%+), or `labelColor` when no data — applied via `NSImage.SymbolConfiguration(paletteColors:)`. The percentage text always uses `labelColor`. Cache is keyed on icon + text + color + `NSApp.effectiveAppearance` name; appearance changes are observed via KVO and invalidate the cache. Notification preferences are persisted per-key; `notifyBanner` is stored under `"notifyOnReset"` for backwards compatibility. Pace system: appends utilization readings to a rolling history window (`paceHistoryMinutes`, default 15 min); `pace(for:)` requires 30 s of elapsed history before returning a rate. Reset detection uses parsed `Date` values (not raw strings) with a 1-hour threshold to guard against server timestamp noise.
- **Models.swift** — Codable structs matching the API response: `UsageResponse` with `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` windows, each containing `utilization` (0–100%) and `resets_at` (ISO 8601). `UsageWindow.resetsAtDate` parses the timestamp with two formatters (with and without fractional seconds) because the server returns both forms. `AccountInfo` derives the subscription label from `memberships[0].organization.capabilities` (e.g. `"claude_max"`) and `rate_limit_tier` (e.g. `"default_claude_max_5x"`). Also `MenuBarWindow` enum for the display picker.
- **LoginView.swift** — `NSViewRepresentable` wrapping the API service's `WKWebView` for in-app browser login. `LoginWindowController` manages the login window lifecycle (singleton, reuses existing window on repeated opens). The login `NSWindow` is created with `isReleasedWhenClosed = false` — omitting this causes a double-free crash (ObjC autorelease + Swift ARC release) during Core Animation teardown.
- **ToastWindowController.swift** — Floating `NSPanel`-based toast notification. Uses `[.borderless, .nonactivatingPanel]` styleMask, `.floating` level, `isOpaque = false`, `backgroundColor = .clear` so the SwiftUI material fills the visual area. Positioned at top-right corner (exact icon position is not accessible from `MenuBarExtra`).
- **MenuBarView.swift** — Popover UI showing per-window progress bars, utilization %, reset countdowns, subscription badge, and extra usage.
- **SettingsView.swift** — Account status, subscription badge, menu bar window picker, notification controls (toast/sound/banner, duration, permanent mode), refresh interval slider, pace indicator toggle with rate window picker (5/10/15/30 min), and pace alert controls.

## Key Constraints

**Menu bar label rendering:** macOS `MenuBarExtra` labels cannot reliably show SF Symbols alongside `Text`. The only approaches that work:
- Plain `Text("string")` with no images
- Single `Image(nsImage:)` with icon + text composited into one `NSImage` (current approach)

The image does **not** use `isTemplate = true` — the icon color is applied via `NSImage.SymbolConfiguration(paletteColors:)` and the text always uses `NSColor.labelColor` (adapts to dark/light mode). Appearance changes are observed via `NSApp.publisher(for: \.effectiveAppearance)` to invalidate the cache and trigger a redraw.

Do NOT attempt `HStack { Image; Text }`, `Label(text, systemImage:)`, `Text("\(Image(...)) text")`, or the `MenuBarExtra(title, systemImage:)` init — all show the icon but hide the text.

**Login window memory management:** The `NSWindow` created by `LoginWindowController` must have `isReleasedWhenClosed = false`. The default (`true`) causes the window to be added to the ObjC autorelease pool on `close()`, while Swift ARC also holds a strong reference via `self.window`. Setting `self.window = nil` after `close()` results in a double-release that crashes during the next Core Animation transaction flush.

**Notifications:** `UNUserNotificationCenterDelegate` must be a separate `NSObject` subclass — assigning a `@MainActor` class as delegate causes Swift concurrency compiler errors. Sound is handled by `NSSound` independently of `UNUserNotificationCenter` to prevent double-play when both channels are enabled.

**Reset detection:** `previousResetsAt` stores parsed `Date` values, not raw `resets_at` strings. The API returns timestamps in varying ISO 8601 formats (with/without fractional seconds) and may use rolling expiry times — string equality would fire spurious reset notifications on every poll. A reset is only declared when the new expiry date is **more than 1 hour later** than the stored one (`newDate.timeIntervalSince(oldDate) > 3600`), which real resets (5-hour: ~5 h jump, 7-day: ~7 d jump) always satisfy.

**UserDefaults migration:** `notificationDefaultsVersion` tracks applied migrations. Version 2 reset defaults to toast-only. Increment this key and add a migration block in `UsageViewModel.init()` whenever defaults need to change for existing installs.

**Sandboxing:** The app is sandboxed with only `com.apple.security.network.client`. It cannot write to the Desktop or other user directories — use `NSTemporaryDirectory()` for any debug output (maps to `~/Library/Containers/com.claudetracker.app/Data/tmp/`).

**SourceKit false positives:** Persistent "Cannot find type X in scope" errors appear in SourceKit for all cross-file references. These are IDE-level issues and do not reflect real build errors. All builds succeed normally.

## API Notes

The app uses **unofficial, undocumented** claude.ai endpoints via WKWebView `fetch()`:
- `GET /api/account` — account profile (name, email, memberships with capabilities and rate_limit_tier)
- `GET /api/organizations` — org list with UUIDs
- `GET /api/organizations/{id}/usage` — usage windows (five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage)

Auth is handled by cookies in the WKWebView's `.default()` data store (shared between login and API webviews). Direct `URLSession` requests to claude.ai are blocked by Cloudflare. The subscription tier has no dedicated field — it is inferred from `capabilities` + `rate_limit_tier` in the memberships array.
