# ClaudeTracker

A macOS menu bar app that shows your [Claude AI](https://claude.ai) usage limits in real time — utilization percentages, progress bars, and countdown timers until each window resets.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- Live 5-Hour and 7-Day utilization bars with color-coded thresholds (green / orange / red)
- Reset countdowns with relative time display ("resets in 3 hours")
- Menu bar label showing the selected window's utilization percentage at a glance
- Subscription badge (Pro, Max 5x, Max 20x, Team, Enterprise)
- Configurable notifications when a window resets: toast near the menu bar, sound, and system banner
  - Toast duration slider (1-30 s) or permanent mode until dismissed
- Configurable refresh interval (1-60 seconds, default 5 s)
- No API key required — uses your existing claude.ai browser session

## Requirements

- macOS 14 Sonoma or later
- Xcode 15 or later (build from source only)
- An active [Claude](https://claude.ai) account (Pro, Max, Team, or Enterprise)

## Installation

### Download a release

1. Go to [Releases](https://github.com/diegovilloutafredes/ClaudeTracker/releases) and download the latest `ClaudeTracker.zip`
2. Unzip it
3. Double-click `install.command` — it copies the app to `/Applications`, strips the Gatekeeper quarantine flag, and launches it

The quarantine flag is removed automatically by the installer. No manual `xattr` step is needed.

> If you drag the app to Applications yourself instead of using `install.command`, macOS will block the first launch because the app is not signed with a Developer ID certificate. Right-click the app and choose Open to proceed.

### Build from source

```bash
git clone https://github.com/diegovilloutafredes/ClaudeTracker.git
cd ClaudeTracker
make release
```

The build output lands at `release/ClaudeTracker.zip`. To install immediately:

```bash
cd release/dist
bash install.command
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
| `UsageViewModel.swift` | Published state, polling timer, UserDefaults persistence, notification dispatch |
| `Models.swift` | Codable structs for API responses; `MenuBarWindow` display enum |
| `LoginView.swift` | `NSViewRepresentable` wrapping the API web view; `LoginWindowController` |
| `ToastWindowController.swift` | Floating `NSPanel`-based toast, positioned near the top-right corner |
| `MenuBarView.swift` | Popover content — progress bars, reset countdowns, extra usage |
| `SettingsView.swift` | Account status, display picker, notification and refresh settings |

## Disclaimer

This app uses **unofficial, undocumented** internal claude.ai endpoints. It is not affiliated with, endorsed by, or supported by Anthropic. The API may change at any time without notice. Use at your own risk.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
