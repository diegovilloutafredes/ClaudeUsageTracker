# ClaudeTracker

A macOS menu bar app that shows your [Claude AI](https://claude.ai) usage limits in real time — utilization percentages, progress bars, and countdown timers until each window resets.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- Live 5-Hour and 7-Day utilization bars with color-coded thresholds (green / orange / red)
- Reset countdowns with relative time display ("resets in 3 hours")
- Menu bar label showing the selected window's utilization percentage at a glance; the icon is color-coded green / orange / red while the percentage stays in the default system color
- Subscription badge (Pro, Max 5x, Max 20x, Team, Enterprise)
- **Pace indicator** — shows current consumption rate (%/hr) and projected time to full; configurable rate window (5/10/15/30 min)
- **Pace alerts** — toast/sound/banner notification when a window is projected to fill before it resets; auto-dismissed when pace improves past the warning threshold
- Configurable notifications when a window resets: toast near the menu bar, sound, and system banner
  - Toast duration slider (1-30 s) or permanent mode until dismissed
- **Popup scale** — slider (75–150%) to resize the popover proportionally
- **Update checker** — checks GitHub Releases on launch and in Settings; shows a download link when a newer version is available
- Configurable refresh interval (1-60 seconds, default 5 s)
- No API key required — uses your existing claude.ai browser session

## Requirements

- macOS 14 Sonoma or later
- Xcode 15 or later (build from source only)
- An active [Claude](https://claude.ai) account (Pro, Max, Team, or Enterprise)

## Installation

### Download a release

Go to [Releases](https://github.com/diegovilloutafredes/ClaudeTracker/releases) and download the latest version. Two formats are provided:

**DMG (recommended)**
1. Open `ClaudeTracker.dmg`
2. Drag `ClaudeTracker.app` to the `/Applications` shortcut in the window
3. Launch from Applications

**ZIP (fallback)**
1. Download `ClaudeTracker.zip` and unzip it
2. Double-click `install.command` — it copies the app to `/Applications`, strips the Gatekeeper quarantine flag, and launches it

> Because the app is not yet signed with a Developer ID certificate, macOS may block the first launch. If that happens, right-click the app and choose **Open**, or run `xattr -d com.apple.quarantine /Applications/ClaudeTracker.app`.

### Build from source

```bash
git clone https://github.com/diegovilloutafredes/ClaudeTracker.git
cd ClaudeTracker
make run
```

This builds, installs to `/Applications/`, and launches the app in one step.

To package distributable artifacts (DMG + ZIP):

```bash
make release
# Outputs: release/ClaudeTracker.dmg and release/ClaudeTracker.zip
```

To sign and notarize (requires Apple Developer ID credentials):

```bash
make release \
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  APPLE_ID=you@example.com \
  APPLE_PASSWORD=xxxx-xxxx-xxxx-xxxx \
  APPLE_TEAM_ID=TEAMID
```

### First launch

1. Click the menu bar icon (shows a percentage, or `--` when not signed in)
2. Click **Sign in to Claude** — a browser window opens with claude.ai
3. Sign in normally; the app detects the session cookie automatically
4. The window closes and usage data loads within a few seconds

## How it works

Claude.ai uses Cloudflare bot-detection that blocks plain `URLSession` requests. The app loads `claude.ai` in a hidden `WKWebView` and issues all API calls via `callAsyncJavaScript`. Requests originate from a real browser context with the correct cookies, headers, and TLS fingerprint — the same way the web app works.

Authentication is handled by the shared WKWebView cookie store. Signing in once persists the session across relaunches until you explicitly sign out.

## Architecture

| File | Responsibility |
|---|---|
| `ClaudeTrackerApp.swift` | App entry point, `MenuBarExtra` scene, composed menu bar image |
| `ClaudeAPIService.swift` | Hidden `WKWebView` for API calls; login page loading and cookie polling |
| `UsageViewModel.swift` | Published state, polling timer, UserDefaults persistence, notification dispatch, update checker |
| `Models.swift` | Codable structs for API responses; `MenuBarWindow` display enum; `UpdateInfo` |
| `LoginView.swift` | `NSViewRepresentable` wrapping the API web view; `LoginWindowController` |
| `ToastWindowController.swift` | Floating `NSPanel`-based toast, positioned near the top-right corner |
| `MenuBarView.swift` | Popover content — scalable progress bars, reset countdowns, extra usage |
| `SettingsView.swift` | Account status, update checker, popup scale, notification and refresh settings |

## Disclaimer

This app uses **unofficial, undocumented** internal claude.ai endpoints. It is not affiliated with, endorsed by, or supported by Anthropic. The API may change at any time without notice. Use at your own risk.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
