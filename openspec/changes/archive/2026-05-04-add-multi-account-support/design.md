## Context

ClaudeTracker is a single-account menu bar app: `ClaudeAPIService` owns one `WKWebView` backed by `WKWebsiteDataStore.default()`, and `UsageViewModel` keeps one set of usage / pace / chart state. The `sessionKey` cookie that authenticates API calls lives in the shared cookie jar — signing in to a second account overwrites the first, with no way to keep both alive.

Users with both a personal and a work Claude account (a common Max-plan pattern) want to keep both signed in and pivot between them from the menu bar. The deployment target is macOS 14+, which gives us first-class per-identifier data stores via `WKWebsiteDataStore(forIdentifier:)`.

## Goals / Non-Goals

**Goals:**
- Multiple accounts coexist with fully isolated cookies and per-account state.
- Account switching is a one-click action from the popover header.
- Existing single-account installs upgrade silently (no re-login required).
- The change is invisible to users with one account — UI looks the same as today until they add a second.

**Non-Goals:**
- No simultaneous polling of inactive accounts. Only the active account polls; switching triggers a fresh fetch.
- No menu bar aggregation across accounts ("highest util across all"). Out of scope.
- No background notifications for inactive accounts.
- No iCloud / cross-device sync of the account list.
- No password / biometric protection of the account picker.

## Decisions

### 1. Per-account `WKWebsiteDataStore(forIdentifier:)` over single store with cookie-swapping

`WKWebsiteDataStore(forIdentifier: UUID)` (macOS 14+) gives each account its own cookie jar, IndexedDB, service workers, etc. — fully isolated, persisted across launches, and cleaned up when we destroy the store.

**Rejected:** swapping cookies in/out of `.default()` on every account switch. Cloudflare bot-detection state and other persisted artifacts would leak across accounts; race conditions during switch (in-flight `fetch` against the wrong cookies) are nasty; and the per-identifier API was added precisely to avoid this.

**Cost:** each account holds its own WebKit web-content process while it has a live `WKWebView`. We instantiate a `WKWebView` only for the active account — inactive accounts hold just the `Account` metadata and the `dataStoreIdentifier`; their `WKWebView` is created lazily on switch.

### 2. One `ClaudeAPIService` per account, only the active one is alive

`ClaudeAPIService` becomes a per-account object: `init(dataStoreIdentifier: UUID)` builds its `WKWebView` against `WKWebsiteDataStore(forIdentifier:)`. `UsageViewModel` holds `activeAPIService: ClaudeAPIService?` and tears it down (cancel timer, drop the service, releasing the web view) when switching accounts. The new account's service is constructed on demand.

**Rejected:** keeping a long-lived dictionary `[AccountID: ClaudeAPIService]`. With N accounts that's N hidden `WKWebView`s in memory and N web-content processes — wasteful for a menu bar app and the only benefit (instant switch) doesn't justify the cost. Switching takes ~1 fetch round-trip; that's fine.

### 3. Per-account state buckets in `UsageViewModel`, not per-account ViewModels

A single `UsageViewModel` keeps the existing `@Observable` surface (which the `MenuBarView`, `SettingsView`, and menu bar label all bind to) and stores per-account state in dictionaries keyed by `accountID`:

```
var usageByAccount: [UUID: UsageResponse]
var historyByAccount: [UUID: [UsageDataPoint]]
var utilizationHistoryByAccount: [UUID: [String: [(Date, Double)]]]
var previousResetsAtByAccount: [UUID: [String: Date]]
var paceWarnedByAccount: [UUID: Set<String>]
var paceToastIDsByAccount: [UUID: [String: UUID]]
```

Computed accessors return the active account's slice (`var usage: UsageResponse? { usageByAccount[activeAccountID] }`), so the existing view layer reads the same property names.

**Rejected:** a `PerAccountViewModel` per account, with a top-level `AppViewModel` switching between them. Cleaner factoring on paper, but it forces every view binding to thread the active VM, and most computed-state code (menu bar image, status colour) doesn't change at all per-account — keeping it in one VM keeps the diff small.

### 4. UserDefaults schema and namespacing

New keys (top level):
- `accounts` — JSON array of `Account { id: UUID, label: String, email: String?, subscriptionLabel: String?, dataStoreIdentifier: UUID, addedAt: Date }`
- `activeAccountID` — UUID string of the active account

Existing per-account keys are namespaced: `usageHistory.<accountID>` instead of the global `usageHistory`. We **do not** namespace user preferences (`notify5Hour`, `paceRateUnit`, `popupScale`, etc.) — those are app-wide.

**Migration on first launch under the new build:**
1. If `accounts` key already exists → already migrated, no action.
2. Else, check if `WKWebsiteDataStore.default()` has a claude.ai `sessionKey` cookie.
   - **Yes** → create one `Account` with a fresh `dataStoreIdentifier` UUID, copy the cookies from `.default()` into the new identified store, set `activeAccountID`, rename `usageHistory` → `usageHistory.<newID>`, write `accounts` and `activeAccountID`.
   - **No** → write `accounts: []`, `activeAccountID: null`. App starts in empty state.

Cookie copy is the trickiest step (point 6).

### 5. Account labelling

Default label = `AccountInfo.displayName` (full name → email fallback). We fetch `/api/account` once after a new account is added and store the returned `displayName`, `emailAddress`, and `subscriptionLabel` into the `Account` record. The user can rename it from Settings.

The picker shows `label` + the subscription badge (Max 5×, Max 20×, Pro …) so two "Diego" accounts on different tiers stay distinguishable.

### 6. Cookie copy during migration

`WKHTTPCookieStore.getAllCookies` + filter by `.claude.ai` / `anthropic.com` domain + `setCookie` on the new store, all inside an async barrier before we instantiate the new `ClaudeAPIService`. We **do not delete** from `.default()` afterwards — leaving them avoids breaking the migration if the user downgrades, and `.default()` is no longer used by the app post-migration so the orphans are harmless.

### 7. Account switching behaviour

When the user picks a different account:
1. Cancel the current `fetchTask` and `timer`.
2. Tear down the current `ClaudeAPIService` (it cleans up its `WKWebView`).
3. Update `activeAccountID` (persist immediately).
4. Build a new `ClaudeAPIService` against the new account's `dataStoreIdentifier`.
5. Reset transient menu bar state (force `cachedMenuBarKey = ""`, recompute label from the new account's stored `usage` slice — which may be `nil`).
6. Trigger `fetchUsage()`. The popover shows the cached `usage` for that account immediately (if any), or the loading state if it's a never-fetched account.

A switch never produces a reset notification — `previousResetsAt` is per-account and survives the switch.

### 8. Adding an account

The "Add account…" entry in the picker (and "Add account" button in the empty state) calls `LoginWindowController.open(forNewAccount: true, ...)`. The login window's embedded `WKWebView` uses a freshly-created `WKWebsiteDataStore(forIdentifier:)` so the new `sessionKey` cookie lands in the new jar from the start. Once cookie polling detects the session, we instantiate the `Account` record (with a placeholder label until `/api/account` resolves), persist the roster, set it as active, and dismiss the login window.

If the user opens the login window and closes it without signing in, the orphaned data store is removed (`WKWebsiteDataStore.remove(forIdentifier:)`).

### 9. Removing an account

Settings → "Accounts" → trash icon. Confirmation alert. On confirm:
1. If it's the active account, switch to the next one (or empty state if none).
2. Call `WKWebsiteDataStore.remove(forIdentifier:)` to wipe cookies/storage.
3. Remove the namespaced UserDefaults keys (`usageHistory.<id>`).
4. Remove from `accounts`.

There is no undo.

### 10. Empty state and single-account UI

- Zero accounts: existing "Sign in to Claude" empty state, but the button label becomes "Add a Claude account". Login flow goes through the new-account path.
- One account: header shows the account label as plain text + subscription badge — **no picker**, identical to today's UI.
- Two or more accounts: header label becomes a `Menu`-style button (chevron) listing all accounts + "Add account…" entry.

This keeps the "no visible UI change for single-account users" promise.

## Risks / Trade-offs

- **WKWebsiteDataStore identifier persistence**: WebKit guarantees the per-identifier store survives app relaunches but offers no API to enumerate existing ones. We rely on `accounts` in UserDefaults as the source of truth; if that key is wiped (manual `defaults delete`) the cookies become orphaned in WebKit's storage and we have no way to surface them. → Mitigation: not user-facing — `defaults delete` is also a self-inflicted reset for every other persisted setting.
- **Migration cookie copy could fail silently** if `.default()` returns no cookies despite the user being signed in (e.g. partial Cloudflare state). → Mitigation: if the post-copy verification step (read back from the new store) finds no `sessionKey`, fall back to "no accounts" state and prompt the user to sign in. Log the migration outcome via `AppLogger`.
- **Cloudflare may rate-limit a flurry of separate browser sessions** if the user adds many accounts quickly. → Mitigation: only the active account's `WKWebView` ever fetches; idle accounts don't talk to the network at all.
- **Storage cost**: each `WKWebsiteDataStore` carries its own caches/IndexedDB. Typical claude.ai footprint is small (single-digit MB) but N accounts multiply it. Acceptable for an app whose audience is power users with 1-3 accounts.
- **Renaming an account** is local-only — claude.ai does not get the new label. Users may forget that and confuse a renamed account with another. → Mitigation: always show the email (smaller, secondary text) under the label in the picker.
- **macOS 14+ requirement** is already the deployment target, so `WKWebsiteDataStore(forIdentifier:)` is safe.

## Migration Plan

1. Ship the new build. On first launch the `init` migration block runs once (`accountsMigrationVersion = 1`), copies the existing session into a per-identifier store, and writes the `accounts` / `activeAccountID` keys.
2. The existing `usageHistory` blob is moved to `usageHistory.<id>` for the migrated account.
3. The old `.default()` cookies are intentionally **not** deleted (cheap insurance against rollback).
4. **Rollback**: a previous version reading the old `usageHistory` key still finds it absent — it would behave as a fresh install (empty chart history, but cookies in `.default()` are untouched so the user is still signed in). Acceptable degradation.

## Open Questions

- **Order of accounts in the picker** — chronological-added vs. alphabetical-by-label? Defaulting to add-order; revisit if users with many accounts complain.
- **Should "Sign out" still exist as a per-account action separate from "Remove account"?** Defaulting to no — remove implies sign out. If a user wants to keep an account in the list but logged out, they can re-add it later. Lower mental model load.
- **What happens to a pace alert that is mid-toast when the user switches accounts?** Defaulting to: dismiss it (it belonged to the previous account's window). The per-account `paceToastIDs` map is consulted on switch; any active toasts for the outgoing account are dismissed.
