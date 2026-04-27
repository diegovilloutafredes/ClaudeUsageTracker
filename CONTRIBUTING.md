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

The `make release` command (see below) does the full build + package cycle. To install the resulting binary:

```bash
cd release/dist && bash install.command
```

## Cutting a release

```bash
make tag VERSION=1.2.0
```

This checks for a clean working directory, bumps `MARKETING_VERSION` in the Xcode project, commits the change, creates an annotated git tag, and pushes both the commit and the tag. The GitHub Actions release workflow triggers on the tag push and publishes a GitHub Release with the built zip attached.

Release notes are auto-generated from commit messages between tags. Write commit messages as complete sentences describing what changed and why — they become the release changelog.

## Future automation options

The current release process (manual `make tag`) is intentionally simple. If the project grows, consider:

- **[git-cliff](https://github.com/orhun/git-cliff)** — generates a `CHANGELOG.md` from conventional commit messages. Add `cliff.toml` at the repo root and run `git cliff --tag v1.x.0` before tagging to produce release notes.
- **[Conventional Commits](https://www.conventionalcommits.org)** — a commit message convention (`feat:`, `fix:`, `chore:`) that tools like git-cliff and semantic-release parse to determine version bumps automatically.
- **Automated version bump** — a GitHub Actions workflow on `main` that reads the latest tag, bumps the patch version, and opens a "Release v1.x.0" PR. Merge the PR to publish.

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
