# ClaudeUsageTracker

A macOS menu bar app that shows your [Claude AI](https://claude.ai) usage in real time — utilization percentages, progress bars, and countdown timers until each window resets.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Live usage windows** — 5-Hour and 7-Day utilization bars with color-coded thresholds
- **Reset countdowns** — relative time display ("resets in 3 hours")
- **Menu bar label** — shows the selected window's utilization % at a glance
- **Subscription badge** — displays your plan (Pro, Max 5×, Max 20×, Team, Enterprise)
- **Notifications** — configurable toast, sound, and system banner when a window resets
  - Toast: anchored near the menu bar, auto-dismisses or stays until closed
  - Duration slider (1–30 s) or permanent mode
- **Configurable refresh interval** — 1–60 seconds (default 5 s)
- **No API key required** — uses your existing claude.ai browser session

## Requirements

- macOS 14 Sonoma or later
- Xcode 15 or later
- An active [Claude](https://claude.ai) account (Pro, Max, Team, or Enterprise)

## Installation

### Download a release

1. Go to [Releases](https://github.com/diegovilloutafredes/ClaudeUsageTracker/releases) and download the latest `ClaudeUsageTracker.zip`
2. Unzip and double-click `install.command` — it copies the app to `/Applications` and launches it

**Gatekeeper note:** Because the app is not signed with an Apple Developer ID, macOS will block it on first launch. To allow it, right-click `ClaudeUsageTracker.app` → Open → Open. Alternatively:

```bash
xattr -dr com.apple.quarantine /Applications/ClaudeUsageTracker.app
```

### Build from source

```bash
git clone https://github.com/diegovilloutafredes/ClaudeUsageTracker.git
cd ClaudeUsageTracker
make release
```

The built zip lands at `release/ClaudeUsageTracker.zip`. Or use the convenience script after building:

```bash
bash install.command
```

### First launch

1. Click the menu bar icon (percentage or `—` if not yet signed in)
2. Click **Sign in to Claude** — a browser window opens with claude.ai
3. Sign in normally; the app detects the session cookie automatically
4. The window closes and usage data loads within a few seconds

## Architecture

| File | Responsibility |
|---|---|
| `ClaudeUsageTrackerApp.swift` | App entry, `MenuBarExtra`, composed menu bar image |
| `ClaudeAPIService.swift` | Hidden `WKWebView` calling `fetch()` — bypasses Cloudflare |
| `UsageViewModel.swift` | State, polling (Combine), persistence (UserDefaults), notifications |
| `Models.swift` | Codable structs for API responses; `MenuBarWindow` enum |
| `LoginView.swift` | `NSViewRepresentable` wrapping the API webview for login |
| `ToastWindowController.swift` | Transparent `NSPanel`-based toast, anchored near menu bar |
| `MenuBarView.swift` | Popover UI — progress bars, reset countdowns |
| `SettingsView.swift` | Account info, display picker, notification & refresh settings |

### Why WKWebView instead of URLSession?

Claude.ai uses Cloudflare bot protection that blocks plain `URLSession` requests. By loading `claude.ai` in a hidden `WKWebView` and calling the API via `callAsyncJavaScript`, requests carry the correct browser fingerprint and session cookies — exactly as the web app does.

## Disclaimer

This app uses **unofficial, undocumented** internal claude.ai endpoints. It is not affiliated with, endorsed by, or supported by Anthropic. The API may change at any time without notice. Use at your own risk.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
