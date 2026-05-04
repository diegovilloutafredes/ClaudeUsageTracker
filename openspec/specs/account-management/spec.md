# account-management Specification

## Purpose
TBD - created by archiving change add-multi-account-support. Update Purpose after archive.
## Requirements
### Requirement: Multiple accounts coexist with isolated sessions

The system SHALL maintain a list of zero or more Claude accounts, each backed by its own `WKWebsiteDataStore(forIdentifier:)` so that authentication cookies (including `sessionKey`) for one account never affect any other account.

#### Scenario: Two accounts stay signed in simultaneously

- **WHEN** the user signs in to account A, then adds account B without signing A out
- **THEN** both accounts SHALL appear in the account picker
- **AND** switching between A and B SHALL NOT require re-authentication on either account
- **AND** the `sessionKey` cookie of account B SHALL NOT exist in account A's data store

#### Scenario: Removing an account wipes only that account's session

- **WHEN** the user removes account B from Settings
- **THEN** the system SHALL call `WKWebsiteDataStore.remove(forIdentifier:)` for B's identifier
- **AND** account A SHALL remain signed in and pollable
- **AND** B SHALL no longer appear in the picker

### Requirement: Active account drives all displayed and tracked state

The system SHALL designate exactly one account as **active** at any time when the account roster is non-empty. All popover content, the menu bar label, the menu bar image, charts, pace, reset detection, and notifications SHALL reflect the active account only. Inactive accounts SHALL NOT poll the API.

#### Scenario: Menu bar reflects only the active account

- **WHEN** the active account's 5-hour utilization is 80% and an inactive account's 5-hour utilization (last known) is 20%
- **THEN** the menu bar label SHALL display 80%

#### Scenario: Inactive accounts do not consume API quota

- **WHEN** the user is on account A and account B has been added but is inactive
- **THEN** no `fetch` against `/api/organizations/.../usage` SHALL be issued for B until B becomes active

#### Scenario: Switching account changes displayed content

- **WHEN** the user picks a different account from the picker
- **THEN** the system SHALL cancel the in-flight fetch and timer for the previous account
- **AND** the system SHALL set the new `activeAccountID` and persist it
- **AND** the popover SHALL display the new account's last-known usage immediately (or a loading state if none)
- **AND** the system SHALL trigger a fresh `fetchUsage` against the new account
- **AND** no reset notification SHALL fire as a side effect of the switch

### Requirement: Per-account state is isolated

The system SHALL store usage data, pace utilization history, chart history, reset-detection timestamps, pace-warned flags, and pace-toast IDs **per account** so that switching accounts never surfaces another account's data, pace alert, or reset notification.

#### Scenario: Chart history does not cross accounts

- **WHEN** the user switches from account A (with 24 h of chart history) to account B (newly added)
- **THEN** the Charts tab SHALL show "No data for this period" for account B
- **AND** switching back to A SHALL restore A's full 24 h of history

#### Scenario: Pace warning state does not transfer across accounts

- **WHEN** account A has already triggered a pace alert in its current 5-hour window
- **AND** the user switches to account B and then back to A
- **THEN** account A SHALL NOT re-fire the same pace alert (its `paceWarned` set persists across the switch)

### Requirement: Account roster persists across launches

The system SHALL persist the account list (`accounts`) and the active account selection (`activeAccountID`) in `UserDefaults`, and SHALL restore both on next launch.

#### Scenario: Active account survives relaunch

- **WHEN** the user quits the app while account B is active
- **AND** the user launches the app again
- **THEN** account B SHALL be the active account on launch
- **AND** the account picker SHALL list every previously added account in the same order

#### Scenario: Per-account chart history persists across launches

- **WHEN** the user quits with two accounts each holding distinct chart histories
- **AND** the user launches the app again
- **THEN** each account's history SHALL be intact and accessible by switching to it

### Requirement: First-launch migration preserves the existing single account

On the first launch under the multi-account build, the system SHALL detect any existing `sessionKey` cookie in `WKWebsiteDataStore.default()`, copy it into a newly created `WKWebsiteDataStore(forIdentifier:)`, register a single `Account` for that session, mark it active, and migrate the legacy `usageHistory` UserDefaults key to the per-account namespace. The migration SHALL run at most once (gated by a `accountsMigrationVersion` UserDefaults key).

#### Scenario: Existing user upgrades without re-login

- **WHEN** a user who was signed in under the previous (single-account) build launches the new build for the first time
- **THEN** the system SHALL create one `Account` entry from the existing cookies
- **AND** the user SHALL NOT be prompted to sign in again
- **AND** the previously collected chart history SHALL be visible under that account
- **AND** the migration SHALL NOT run again on subsequent launches

#### Scenario: Existing user with no session migrates to empty state

- **WHEN** a user with no `sessionKey` cookie launches the new build
- **THEN** the system SHALL persist `accounts: []` and `activeAccountID: nil`
- **AND** the popover SHALL show the empty state with "Add a Claude account"
- **AND** the migration SHALL be marked complete so it does not re-run

### Requirement: User can add a new account

The system SHALL provide an "Add account" affordance both in the empty state and in the account picker (when at least one account exists). Selecting it SHALL open the existing login window, but the embedded `WKWebView` SHALL use a freshly created `WKWebsiteDataStore(forIdentifier:)` so the resulting `sessionKey` cookie is isolated to the new account.

#### Scenario: Adding an account from the picker

- **WHEN** the user has at least one account and selects "Add account…" from the picker
- **THEN** the login window SHALL open against a new data store identifier
- **AND** upon detecting a `sessionKey` cookie, the system SHALL persist a new `Account` record (with a placeholder label until `/api/account` resolves the display name)
- **AND** the new account SHALL become active
- **AND** the login window SHALL dismiss automatically

#### Scenario: Cancelling an add does not leak data stores

- **WHEN** the user opens the login window for a new account but closes it before signing in
- **THEN** the system SHALL call `WKWebsiteDataStore.remove(forIdentifier:)` for the unused identifier
- **AND** the `accounts` list SHALL remain unchanged

### Requirement: User can rename an account

The system SHALL allow the user to edit an account's display label from Settings. The label SHALL default to the API-provided `displayName` (full name → email fallback) and SHALL be stored locally only.

#### Scenario: Rename persists and updates UI

- **WHEN** the user renames "Diego Villouta" to "Personal"
- **THEN** the picker, header, and Settings list SHALL all show "Personal"
- **AND** the rename SHALL persist across relaunches

### Requirement: User can remove an account

The system SHALL allow the user to remove any account from Settings, after a confirmation prompt. Removal SHALL delete the account's `WKWebsiteDataStore`, the namespaced UserDefaults entries (`usageHistory.<id>`), and the entry in `accounts`.

#### Scenario: Removing the active account switches to another

- **WHEN** the user removes the currently active account
- **AND** at least one other account exists
- **THEN** the system SHALL designate the next account in the list as active
- **AND** trigger a fresh fetch against the new active account

#### Scenario: Removing the only account returns to empty state

- **WHEN** the user removes the only account
- **THEN** `activeAccountID` SHALL become `nil`
- **AND** the popover SHALL show the empty state
- **AND** the menu bar label SHALL show the unauthenticated indicator

### Requirement: UI degrades cleanly to single-account mode

When exactly one account exists, the popover header SHALL display the account label and subscription badge as plain text — no picker, chevron, or switcher control SHALL be shown. When two or more accounts exist, the same area SHALL become an interactive picker.

#### Scenario: Single-account user sees no UI change vs. previous version

- **WHEN** the user has exactly one account
- **THEN** the popover header SHALL be visually equivalent to the previous (single-account) version
- **AND** no menu, chevron, or extra control SHALL be added

#### Scenario: Two-account user sees the picker

- **WHEN** the user has exactly two accounts
- **THEN** the header SHALL render an interactive picker control listing both accounts plus an "Add account…" entry

