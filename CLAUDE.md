# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

ClaudeTracker — a macOS menu bar app that monitors Claude AI usage limits in real time. It polls the unofficial claude.ai web API and displays utilization percentages and reset countdowns. Open source, MIT licensed.

## Build & Deploy

Use the Makefile. Full clean cycle is required for every change (macOS caches stale binaries otherwise):

```bash
make run   # clean + build + install into /Applications/ + launch
```

Other Makefile targets:

| Target | Purpose |
|---|---|
| `make run` | Clean + build + install into `/Applications/` + launch |
| `make build` | Clean + build Release into `release/build/` |
| `make zip` | Package `release/dist/` → `release/ClaudeTracker.zip` (with `install.command`) |
| `make dmg` | Create `release/ClaudeTracker.dmg` with Applications symlink via `hdiutil` |
| `make sign` | Codesign with `--options runtime`; silently skips if `SIGN_IDENTITY` not set |
| `make notarize` | Submit to Apple notarization; silently skips if `APPLE_ID` not set |
| `make staple` | Staple the notarization ticket; silently skips if `APPLE_ID` not set |
| `make release` | Full pipeline: build → sign → notarize → staple → dmg → zip |
| `make tag VERSION=x.y.z` | Bump `MARKETING_VERSION`, commit, tag, push — triggers CI release |
| `make clean` | Remove all build artifacts |

Never `cp -R` over an existing `/Applications/ClaudeTracker.app` — Launch Services caches the old binary. Always delete first, then copy. `make run` and `install.command` both do this automatically.

Requires macOS 14+ (Sonoma) and Xcode 15+. No external dependencies.

## Releases

Cutting a release:

```bash
make tag VERSION=1.2.0
```

This requires a clean working directory. It bumps `MARKETING_VERSION` in `ClaudeTracker.xcodeproj/project.pbxproj`, commits the bump, creates an annotated git tag, and pushes both the commit and the tag. The GitHub Actions release workflow (`.github/workflows/release.yml`) triggers on the tag and publishes a GitHub Release with the zip attached.

The build uses `SIGNING_FLAGS="CODE_SIGNING_ALLOWED=NO"` and `SWIFT_STRICT_CONCURRENCY=minimal` on CI (both set in the Makefile). Do not remove `SWIFT_STRICT_CONCURRENCY=minimal` — Xcode 16 on `macos-15` treats some concurrency patterns as errors without it.

The release workflow (`.github/workflows/release.yml`) has conditional signing: a `Check signing capability` step outputs `sign=true/false` based on whether `SIGNING_CERTIFICATE` is set as a repo secret. Subsequent sign/notarize/staple steps gate on this output. Both a DMG and a ZIP are attached to every GitHub Release; the ZIP includes `install.command` as a fallback for unsigned installs.

## Architecture

- **ClaudeTrackerApp.swift** — App entry point using `MenuBarExtra` with `.window` style (no dock icon via `LSUIElement`). The label uses a single `Image(nsImage:)` with a composed NSImage.
- **ClaudeAPIService.swift** — Networking via a hidden `WKWebView` that calls `fetch()` through `callAsyncJavaScript`. This bypasses Cloudflare bot protection which blocks plain `URLSession` requests. Also handles login flow (loads claude.ai login page, polls cookies for `sessionKey`). Uses `.defaultClient` content world. OAuth SSO (e.g. "Continue with Google") is handled via `WKUIDelegate.createWebViewWith`: returns a real `WKWebView` built from the *passed* `configuration` (so it shares the data store and `window.opener` is wired). Only `uiDelegate` is set on the popup — `navigationDelegate` is intentionally omitted to prevent popup navigations from misfiring `failAllWaiters`/`checkPageReady` on the main webview. `webViewDidClose` fires when JS calls `window.close()` on the popup. Three properties coordinate with `LoginWindowController`: `popupWebView`, `onPopupRequested`, `onPopupDismissed`.
- **UsageViewModel.swift** — Central state. Manages polling (Combine `Timer.publish`), persistence (`UserDefaults`), rate-limit backoff, session state, and notification dispatch. Generates the composed `menuBarImage` (SF Symbol + text baked into one `NSImage`); the icon and badge color use a continuous urgency gradient via `urgencyNSColor()` (green → yellow → orange → red) based on `effectiveUrgency = max(utilizationUrgency, paceUrgency)` — the icon also elevates when pace alone is high even at low utilization. The percentage text always uses `labelColor`. SF Symbol secondary palette color is `.labelColor` (not `.white`) for contrast at mid-urgency. Cache is keyed on icon + text + color + `NSApp.effectiveAppearance` name; appearance changes are observed via `NSApp.publisher(for: \.effectiveAppearance)` and invalidate the cache. Notification preferences are persisted per-key; `notifyBanner` is stored under `"notifyOnReset"` for backwards compatibility. Pace system: appends utilization readings to a rolling history window (`paceHistoryMinutes`, default 15 min); `pace(for:)` requires 30 s of elapsed history before returning a rate. Reset detection uses parsed `Date` values (not raw strings) with a 1-hour threshold to guard against server timestamp noise. `paceToastIDs: [String: UUID]` tracks active pace-alert toasts; they are dismissed automatically (via `ToastWindowController.dismiss(id:)`) when the pace improves past the warning threshold, or when a window reset is detected in `recordHistory`. `@Published var popupScale: Double` (default `1.0`, persisted under `"popupScale"`) drives proportional scaling of all popover elements. `checkForUpdates()` fetches `api.github.com/repos/.../releases/latest` via plain `URLSession` and posts an `UpdateInfo` to `availableUpdate`; it auto-runs 10 s after launch. Session-recovery: the first consecutive 401 retries silently; a second consecutive 401 marks the session expired and cancels the timer. `usageHistory: [UsageDataPoint]` stores chart snapshots sampled at most once per 5 minutes (throttled by `lastHistoryTimestamp`), pruned to 30 days, capped at 8640 entries, JSON-encoded in UserDefaults under `"usageHistory"`. `showChartsTab: Bool` (persisted under `"showChartsTab"`, default `true`) controls visibility of the Charts tab.
- **Models.swift** — Codable structs matching the API response: `UsageResponse` with `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` windows, each containing `utilization` (0–100%) and `resets_at` (ISO 8601). `UsageWindow.resetsAtDate` parses the timestamp with two formatters (with and without fractional seconds) because the server returns both forms. `UsageWindow.utilizationColor` uses `urgencyColor()` for a continuous green→yellow→orange→red gradient. `urgencyColor(_ urgency: Double) -> Color` is a free function (hue = `0.33 * (1 - t)`) shared by the popover and the AppKit layer (which has a matching `urgencyNSColor` in `UsageViewModel`). `AccountInfo` derives the subscription label from `memberships[0].organization.capabilities` (e.g. `"claude_max"`) and `rate_limit_tier` (e.g. `"default_claude_max_5x"`). Also `MenuBarWindow` enum for the display picker, `UpdateInfo` struct for the update checker, and `UsageDataPoint` (`timestamp`, `fiveHour?`, `sevenDay?`, `Identifiable` by `timestamp`) for the charts history.
- **LoginView.swift** — `NSViewRepresentable` wrapping the API service's `WKWebView` for in-app browser login. `LoginWindowController` (now `@MainActor`) manages the login window lifecycle (singleton, reuses existing window on repeated opens). Also manages the OAuth popup window: `showPopup(webView:)` creates a child `NSWindow` using the `WKWebView` returned by `createWebViewWith`, wired via `onPopupRequested`/`onPopupDismissed` closures on `ClaudeAPIService`. `closePopup()` removes the `NSWindow.willCloseNotification` observer before closing to avoid re-entrancy. Both the login window and the popup window require `isReleasedWhenClosed = false` — omitting this causes a double-free crash (ObjC autorelease + Swift ARC release) during Core Animation teardown.
- **ToastWindowController.swift** — Floating `NSPanel`-based toast notification. Uses `[.borderless, .nonactivatingPanel]` styleMask, `.floating` level, `isOpaque = false`, `backgroundColor = .clear` so the SwiftUI material fills the visual area. Positioned at top-right corner (exact icon position is not accessible from `MenuBarExtra`). `show()` is `@discardableResult` and returns a `UUID`; callers that need caller-driven dismissal store it and call `dismiss(id:)`. Reset-notification call sites discard the UUID; pace-alert call sites store it in `paceToastIDs`.
- **MenuBarView.swift** — Popover UI with two tabs: **Usage** (progress bars, reset countdowns, pace, extra usage) and **Charts** (historical area+line charts). Tab selection is stored in `@AppStorage("selectedTab")` and persists across popover opens. The tab selector is a custom segmented control (`tabButton`) shown only when authenticated and `showChartsTab == true`; toggling `showChartsTab` off resets `selectedTab` to 0 via `onChange`. Charts use `import Charts` (system framework, no xcodeproj change needed); `usageChartSection` renders an `AreaMark` + `LineMark` with `.monotone` interpolation, a hidden x-axis, and 0/50/100% y-axis grid lines. The color per chart matches the urgency gradient of the current utilization for that window. Stats row shows peak and average utilization. All spacing, padding, and font sizes are multiplied by `s = CGFloat(viewModel.popupScale)`. `baseWidth` is `312 * s`. `ChartTimeRange` enum (`5h`/`24h`/`7d`/`30d`) controls how much history is displayed; selection persisted via `@AppStorage("chartTimeRange")`; start date of visible data is shown as a timestamp label below the picker.
- **SettingsView.swift** — Account status, update checker (shows green badge + Download link when an update is available, or "Check for Updates" button), subscription badge, menu bar window picker, popup scale slider (75–150%), "Show charts tab" toggle, pace indicator toggle with rate window picker (5/10/15/30 min), notification controls (toast/sound/banner, duration, permanent mode), refresh interval slider, and pace alert controls. All `Toggle` views use `GreenSwitchStyle`. The window title is set by `SettingsWindowPositioner.makeNSView` to `"Settings · v\(version)"`. The Account section uses a footer with the unofficial API disclaimer.

## Key Constraints

**Toggle styling in Form — NEVER use `.tint` or `.toggleStyle(.switch)` on `Toggle` inside a `Form`:** SwiftUI `Form` with `.formStyle(.grouped)` creates environment-isolation boundaries that prevent `.tint(.green)` from reaching the underlying `NSSwitch` renderer. Any approach relying on environment tint (`.tint(.green)`, per-toggle `.tint`, even `AnyView` wrappers) will regress to system gray whenever macOS redraws the cell. The only permanent fix is `GreenSwitchStyle` — a custom `ToggleStyle` that renders an entirely SwiftUI capsule+circle, bypassing `NSSwitch` and its environment completely. Every `Toggle` in `SettingsView` must use `.toggleStyle(GreenSwitchStyle())`. Do not add `.tint` or `.toggleStyle(.switch)` anywhere in the settings form.

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

**Hardened Runtime:** The Release target build config has `ENABLE_HARDENED_RUNTIME = YES`. This is required for Apple notarization. Do not remove it from the Release configuration in `project.pbxproj`.

**SourceKit false positives:** Persistent "Cannot find type X in scope" errors appear in SourceKit for all cross-file references. These are IDE-level issues and do not reflect real build errors. All builds succeed normally.

## API Notes

The app uses **unofficial, undocumented** claude.ai endpoints via WKWebView `fetch()`:
- `GET /api/account` — account profile (name, email, memberships with capabilities and rate_limit_tier)
- `GET /api/organizations` — org list with UUIDs
- `GET /api/organizations/{id}/usage` — usage windows (five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage)

Auth is handled by cookies in the WKWebView's `.default()` data store (shared between login and API webviews). Direct `URLSession` requests to claude.ai are blocked by Cloudflare. The subscription tier has no dedicated field — it is inferred from `capabilities` + `rate_limit_tier` in the memberships array.
