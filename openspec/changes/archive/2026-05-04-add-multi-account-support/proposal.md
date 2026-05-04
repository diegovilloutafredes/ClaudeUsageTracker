## Why

Today the app supports exactly one Claude account at a time — the single shared `WKWebView` cookie store holds one `sessionKey`, and signing into a second account silently overwrites the first. Users with both a personal and a work Claude account have to keep signing in and out to see the other account's usage, which defeats the point of an always-on menu bar tracker.

## What Changes

- Allow the user to add **multiple Claude accounts** and keep them all signed in simultaneously. Each account is isolated in its own browser session (separate `WKWebsiteDataStore`) so cookies and `sessionKey` never collide.
- Add an **account switcher control** to the popover header. The switcher shows the active account (display name + subscription badge) and lets the user pick a different one or open a "Sign in another account…" entry. The menu bar label, progress bars, charts, pace, and notifications all reflect the active account only.
- Persist the account list (UUID, display name, email, subscription label, datastore identifier) in `UserDefaults` so accounts survive relaunch. Remember which account was last active and restore it on launch.
- Add a "Manage accounts" section to Settings: rename, sign out, or remove individual accounts.
- Per-account state (`usage`, pace history, reset detection, chart history, notification dedup flags) lives **per account** so switching never shows stale or cross-contaminated data.

Non-goals for this change:
- No simultaneous polling of inactive accounts. Only the active account polls; switching triggers a fresh fetch on the new account. (Saves Cloudflare/API quota and keeps the model simple.)
- No menu bar aggregation across accounts (no "highest of all accounts" indicator). Out of scope here.
- No background notifications for inactive accounts.

## Capabilities

### New Capabilities

- `account-management`: Adding, listing, switching between, renaming, and removing Claude accounts; persisting the account roster; isolating each account's web session and per-account state (usage, pace history, charts, reset/pace notification dedup).

### Modified Capabilities

(None — no specs exist yet.)

## Impact

- **Code**:
  - `ClaudeAPIService.swift` — stops being a singleton-with-shared-store; becomes per-account, instantiated against a specific `WKWebsiteDataStore(forIdentifier:)`. Login flow uses the target account's data store so the new `sessionKey` lands in the right cookie jar.
  - `LoginWindowController.swift` — accepts an account identifier (or "new account" sentinel) and routes the embedded `WKWebView` to the matching data store.
  - `UsageViewModel.swift` — gains an `accounts: [Account]`, `activeAccountID`, and per-account state buckets (`usage`, `previousResetsAt`, `utilizationHistory`, `paceWarned`, `paceToastIDs`, `usageHistory`). `signOut()` becomes "remove this account". `startSession`/`fetchUsage` operate on the active account's API service.
  - `MenuBarView.swift` — header gets an account picker (or stays as text when only one account); empty state shows "Add a Claude account" instead of "Sign in".
  - `SettingsView.swift` — new "Accounts" section listing accounts with rename/remove actions; replaces the single "Sign out" button.
  - `Models.swift` — new `Account` struct (id, label, email, subscriptionLabel, dataStoreIdentifier).
- **Persistence (UserDefaults)**:
  - New key `accounts` (JSON-encoded `[Account]`).
  - New key `activeAccountID` (UUID string).
  - Existing single-account keys (`usageHistory`, etc.) get **migrated** into the active account's namespace on first launch under the new model. New keys are namespaced per account (e.g. `usageHistory.<accountID>`).
- **`WKWebsiteDataStore`**: switches from `.default()` to `WKWebsiteDataStore(forIdentifier:)` per account (macOS 14+ API; deployment target is already 14+).
- **No new dependencies**, no new entitlements, no API/network changes.
- **Migration**: existing single-account installs auto-create one `Account` from the current session/cookies on first launch of the new version — invisible to the user.
