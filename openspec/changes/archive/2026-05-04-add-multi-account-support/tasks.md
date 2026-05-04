## 1. Data Model

- [x] 1.1 Add `Account` struct in `Models.swift` (`id: UUID`, `label: String`, `email: String?`, `subscriptionLabel: String?`, `dataStoreIdentifier: UUID`, `addedAt: Date`); make it `Codable`, `Identifiable`, `Hashable`.
- [x] 1.2 Add `AccountStore` helper (in `Models.swift` or new `AccountStore.swift`) responsible for loading/saving the `accounts` JSON array and the `activeAccountID` from `UserDefaults`.

## 2. API Service Refactor

- [x] 2.1 Change `ClaudeAPIService.init()` to `init(dataStoreIdentifier: UUID)`; build the `WKWebViewConfiguration.websiteDataStore` from `WKWebsiteDataStore(forIdentifier:)` instead of `.default()`.
- [x] 2.2 Make `clearCache()` continue to work; add `tearDown()` that cancels the cookie poll, drops the popup, and lets ARC release the `WKWebView`.
- [x] 2.3 Remove the assumption of a singleton service from `LoginWindowController` — accept the target `ClaudeAPIService` per-call (existing API already does this).

## 3. ViewModel — Per-Account State

- [x] 3.1 Add `accounts: [Account]` and `activeAccountID: UUID?` to `UsageViewModel`, persisted via `AccountStore`.
- [x] 3.2 Add per-account dictionaries: `usageByAccount`, `historyByAccount`, `utilizationHistoryByAccount`, `previousResetsAtByAccount`, `paceWarnedByAccount`, `paceToastIDsByAccount`, `lastUpdatedByAccount`, `errorByAccount`.
- [x] 3.3 Replace existing top-level computed properties (`usage`, `error`, `lastUpdated`, `usageHistory`, etc.) with computed accessors that read from / write to the active account's slice.
- [x] 3.4 Replace the singleton `apiService` with `activeAPIService: ClaudeAPIService?`, lazily built when an account becomes active and torn down on switch / removal.
- [x] 3.5 Update `recordHistory`, `appendDataPoint`, `checkForResets`, `checkPaceNotifications`, and `pace(for:)` to read/write the active account's state buckets.

## 4. Persistence & Migration

- [x] 4.1 Namespace the chart-history UserDefaults key per account (`"usageHistory.<accountID>"`); load/save through the active account.
- [x] 4.2 Add a one-shot migration in `UsageViewModel.init()` gated on `accountsMigrationVersion < 1`:
  - [x] 4.2.1 Read all cookies from `WKWebsiteDataStore.default().httpCookieStore`.
  - [x] 4.2.2 If a `sessionKey` cookie exists for `claude.ai`, generate a new `dataStoreIdentifier`, copy the matching cookies (`claude.ai`, `anthropic.com`) into `WKWebsiteDataStore(forIdentifier:)`, verify the copy succeeded by re-reading.
  - [x] 4.2.3 Persist a single `Account` (placeholder label "Claude account"; updated on next `/api/account` fetch), set it as active.
  - [x] 4.2.4 Rename UserDefaults key `usageHistory` → `usageHistory.<id>`.
  - [x] 4.2.5 If no session exists, persist `accounts: []`, `activeAccountID: nil`.
  - [x] 4.2.6 Set `accountsMigrationVersion = 1`.
  - [x] 4.2.7 Log the migration outcome via `AppLogger`.

## 5. Session Lifecycle

- [x] 5.1 Replace `signOut()` with `removeAccount(_ id: UUID)` that: cancels the active fetch+timer if removing the active account, calls `WKWebsiteDataStore.remove(forIdentifier:)`, removes namespaced UserDefaults keys, removes the entry from `accounts`, and switches active if needed.
- [x] 5.2 Add `switchAccount(to id: UUID)` that cancels in-flight work, tears down the current `ClaudeAPIService`, persists the new `activeAccountID`, builds a new `ClaudeAPIService` against the new identifier, dismisses any toasts in the old account's `paceToastIDs`, invalidates `cachedMenuBarKey`, and triggers `fetchUsage()`.
- [x] 5.3 Add `addAccount(label: String?)` that creates a new `Account` with a fresh `dataStoreIdentifier`, persists it, sets it active, and opens the login window against it. Provide a callback path that (on cancel without sign-in) calls `WKWebsiteDataStore.remove(forIdentifier:)` and rolls back the `accounts` write.
- [x] 5.4 After `/api/account` resolves on a newly added or migrated account, write `email`, `subscriptionLabel`, and (if the label was the placeholder) `displayName` back into the `Account` record.

## 6. Login Window Updates

- [x] 6.1 Update `LoginWindowController.open(...)` to accept an optional `Account` (the target account) and instantiate the right `ClaudeAPIService` for that account's data store. The shared service path used for the active-account re-login still works.
- [x] 6.2 Wire the "Add account…" affordance to `addAccount(...)` → `LoginWindowController.open(...)`.

## 7. Popover UI

- [x] 7.1 In `MenuBarView.header`, render the existing label+badge when `accounts.count <= 1`; render an interactive `Menu` (chevron) when `accounts.count >= 2`. Menu items: each account (label + small email subtitle + subscription badge + checkmark on active), Divider, "Add account…".
- [x] 7.2 Hook the picker to `viewModel.switchAccount(to:)` and `viewModel.addAccount(...)`.
- [x] 7.3 Update the empty state (`emptyState`): button label becomes "Add a Claude account" and routes through `addAccount(...)`.
- [x] 7.4 Verify menu bar image (`menuBarImage`) recomputes correctly on switch — invalidate `cachedMenuBarKey` in `switchAccount`.

## 8. Settings UI

- [x] 8.1 Add an "Accounts" section to `SettingsView` listing each `Account`: label (editable), email subtitle, subscription badge, "Sign out & remove" trash button.
- [x] 8.2 Replace the existing "Sign out" button with this list. The list never shows when `accounts.isEmpty` (Settings collapses to its existing logged-out layout).
- [x] 8.3 Removal triggers a confirmation alert (`NSAlert`) before calling `viewModel.removeAccount(_:)`.

## 9. Localization

- [x] 9.1 Add new English + Spanish strings to `Localizable.xcstrings`: "Add a Claude account", "Add account…", "Accounts", "Sign out & remove", "Remove this account?", confirmation body, "Switch account", and any other user-visible additions.

## 10. Verification

- [ ] 10.1 Single-account migration smoke test: install previous build → sign in → upgrade → verify no re-login prompt, chart history intact.
- [ ] 10.2 Add a second account, verify both stay signed in across relaunch.
- [ ] 10.3 Switch accounts mid-poll: confirm in-flight fetch cancels cleanly and no notification fires from the switch.
- [ ] 10.4 Remove the active account with a second account present: confirm switch + namespaced keys deleted (inspect `defaults read com.claudetracker.app`).
- [ ] 10.5 Remove the only account: confirm empty state and `WKWebsiteDataStore.remove(forIdentifier:)` was called (no leftover cookies — verify by adding a fresh account afterwards and confirming the login page does not auto-sign-in).
- [ ] 10.6 Run `make run` per project convention; verify no regressions in pace, charts, notifications, menu bar label.
