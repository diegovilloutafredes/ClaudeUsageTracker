# Contributing

Contributions are welcome — bug fixes, improvements, and new features.

## Getting started

```bash
git clone https://github.com/diegovilloutafredes/ClaudeUsageTracker.git
cd ClaudeUsageTracker
open ClaudeUsageTracker.xcodeproj
```

No external dependencies. Requires macOS 14+ and Xcode 15+.

## Build cycle

macOS caches app binaries aggressively. After any code change, run a full clean cycle:

```bash
pkill -9 -f ClaudeUsageTracker 2>/dev/null; sleep 1
rm -rf /Applications/ClaudeUsageTracker.app
rm -rf ~/Library/Developer/Xcode/DerivedData/ClaudeUsageTracker-*
xcodebuild -project ClaudeUsageTracker.xcodeproj \
           -scheme ClaudeUsageTracker \
           -configuration Debug \
           clean build
```

Then copy and launch:

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "ClaudeUsageTracker.app" -not -path "*/Index.noindex/*" | head -1)
cp -R "$APP" /Applications/
open /Applications/ClaudeUsageTracker.app
```

The `install.command` script at the repo root does all of this in one step.

## Bundle ID note

The app's bundle identifier is `com.claudeusagetracker.app`. UserDefaults keys and the Notification Center identifier are derived from this. If you fork the project and change the bundle ID, update the `UNUserNotificationCenter` category identifier in `UsageViewModel.swift` accordingly.

## Pull requests

1. Fork the repo and create a feature branch
2. Keep changes focused — one concern per PR
3. Test the full build cycle before opening the PR
4. Describe what changed and why in the PR description

## Reporting issues

Use the GitHub issue templates. Include:
- macOS version
- Whether you're on a Pro, Max, or Team plan
- Steps to reproduce
- Any relevant console output (run `Console.app`, filter by `ClaudeUsageTracker`)
