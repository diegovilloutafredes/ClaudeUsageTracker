# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

ClaudeUsageTracker — a macOS menu bar app that monitors Claude AI usage limits in real time. It polls the unofficial claude.ai web API and displays utilization percentages and reset countdowns.

## Build & Deploy

Full clean cycle is **required** for every change (macOS caches stale binaries otherwise):

```bash
pkill -9 -f ClaudeUsageTracker 2>/dev/null; sleep 1
rm -rf /Applications/ClaudeUsageTracker.app
rm -rf ~/Library/Developer/Xcode/DerivedData/ClaudeUsageTracker-*
xcodebuild -project ClaudeUsageTracker.xcodeproj -scheme ClaudeUsageTracker -configuration Debug clean build
# Then find the built .app in DerivedData, cp -R to /Applications, and open it
```

Never just `cp -R` over an existing `/Applications/ClaudeUsageTracker.app` — Launch Services caches the old binary. Always delete first, then copy.

Requires macOS 14+ (Sonoma) and Xcode 15+. No external dependencies.

## Architecture

- **ClaudeUsageTrackerApp.swift** — App entry point using `MenuBarExtra` with `.window` style (no dock icon via `LSUIElement`). The label uses a single `Image(nsImage:)` with a composed NSImage.
- **ClaudeAPIService.swift** — Networking via a hidden `WKWebView` that calls `fetch()` through `callAsyncJavaScript`. This bypasses Cloudflare bot protection which blocks plain `URLSession` requests. Also handles login flow (loads claude.ai login page, polls cookies for `sessionKey`). Uses `.defaultClient` content world.
- **UsageViewModel.swift** — Central state. Manages polling (Combine `Timer.publish`), persistence (`UserDefaults`), rate-limit backoff, session state. Generates the composed `menuBarImage` (SF Symbol + text baked into one `NSImage` with `isTemplate = true`).
- **Models.swift** — Codable structs matching the API response: `UsageResponse` with `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` windows, each containing `utilization` (0-100%) and `resets_at` (ISO 8601). Also `MenuBarWindow` enum for the display picker.
- **LoginView.swift** — `NSViewRepresentable` wrapping the API service's `WKWebView` for in-app browser login. `LoginWindowController` manages the login window lifecycle.
- **MenuBarView.swift** — Popover UI showing per-window progress bars, utilization %, and reset countdowns.
- **SettingsView.swift** — Account status, menu bar window picker, and refresh interval slider (1-60s, default 5s).

## Key Constraints

**Menu bar label rendering:** macOS `MenuBarExtra` labels cannot reliably show SF Symbols/emojis alongside `Text`. The only approaches that work:
- Plain `Text("string")` with no images — works but no icons
- Single `Image(nsImage:)` with icon + text composited into one `NSImage` (current approach, `isTemplate = true` for dark/light mode)

Do NOT attempt `HStack { Image; Text }`, `Label(text, systemImage:)`, `Text("\(Image(...)) text")`, emojis + text, or the `MenuBarExtra(title, systemImage:)` init — all of these show the icon but hide the text.

## API Notes

The app uses **unofficial, undocumented** claude.ai endpoints via WKWebView `fetch()`:
- `GET /api/organizations` — returns org list with UUIDs
- `GET /api/organizations/{id}/usage` — returns usage windows

Auth is handled by cookies in the WKWebView's `.default()` data store (shared between login and API webviews). Direct `URLSession` requests to claude.ai are blocked by Cloudflare.
