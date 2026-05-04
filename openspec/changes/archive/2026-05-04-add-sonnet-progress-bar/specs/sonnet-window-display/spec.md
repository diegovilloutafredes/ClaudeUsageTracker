## ADDED Requirements

### Requirement: Sonnet 7-day window appears in the Usage tab

The popover's Usage tab SHALL render a third progress-bar row labelled "7-Day Sonnet" beneath the existing 7-Day Window row, sourced from `UsageResponse.sevenDaySonnet`. The row SHALL use the existing `UsageWindowView` component so that title, percentage, progress bar, urgency colour, and "Resets …" countdown styling match the other rows exactly.

#### Scenario: Sonnet bar renders for an authenticated Max account

- **WHEN** the user is authenticated and the most recent `/api/organizations/.../usage` response contains a non-null `seven_day_sonnet`
- **AND** the "Show Sonnet usage" Settings toggle is on (default)
- **THEN** the Usage tab SHALL show three rows in this order: 5-Hour Window, 7-Day Window, 7-Day Sonnet
- **AND** the Sonnet row's percentage and progress fill SHALL match `seven_day_sonnet.utilization`
- **AND** the Sonnet row SHALL show "Resets …" using `seven_day_sonnet.resets_at`

#### Scenario: Extra usage row stays last

- **WHEN** the API response includes both `seven_day_sonnet` and an enabled `extra_usage`
- **THEN** the Usage tab SHALL show: 5-Hour Window, 7-Day Window, 7-Day Sonnet, Extra Usage (in that order)

### Requirement: Sonnet row is display-only

The Sonnet row SHALL NOT render a pace line, an outlook line, a reset notification, a pace notification, or any chart/menu-bar entry. The view SHALL pass `paceRate: nil` and `projectedHours: nil` so the existing `UsageWindowView` suppresses pace UI on its own.

#### Scenario: No pace line on the Sonnet row

- **WHEN** the Sonnet row is visible and the user has `showPace = true` and a non-trivial 5h/7d pace
- **THEN** the Sonnet row SHALL NOT show a pace icon, rate, or "full in …" text
- **AND** the 5h and 7d rows' pace lines SHALL be unaffected

#### Scenario: Sonnet does not appear in the menu bar window picker

- **WHEN** the user opens the Settings → Menu Bar Window picker
- **THEN** the picker SHALL only offer "5-Hour Window" and "7-Day Window"
- **AND** SHALL NOT offer a Sonnet option

#### Scenario: No Sonnet entry in chart history

- **WHEN** the Charts tab is open
- **THEN** no Sonnet utilization or pace chart SHALL be rendered
- **AND** `UsageDataPoint` SHALL NOT gain a `sevenDaySonnet` field

### Requirement: Sonnet row is hidden when the API omits the field

The Sonnet row SHALL only render when `UsageResponse.sevenDaySonnet` is non-nil. When the field is missing (e.g., free-tier accounts, account types that do not split Sonnet usage, or future API changes), no placeholder, error, or "no data" message SHALL be shown — the row simply does not appear.

#### Scenario: Free-tier account omits the bar entirely

- **WHEN** the user's API response has `seven_day_sonnet: null` or omits the field
- **THEN** the Usage tab SHALL show only the 5-Hour and 7-Day rows
- **AND** no Sonnet placeholder text SHALL appear

### Requirement: User can toggle Sonnet visibility from Settings

The system SHALL provide a "Show Sonnet usage" toggle in the Settings Display section, persisted under the UserDefaults key `"showSonnetWindow"`. The toggle SHALL default to `true` (on). When set to `false`, the Sonnet row SHALL NOT render even if the API returns a non-nil `seven_day_sonnet`.

#### Scenario: Toggle hides the bar

- **WHEN** the user opens Settings and turns "Show Sonnet usage" off
- **THEN** the Usage tab SHALL stop rendering the Sonnet row immediately
- **AND** the 5h and 7d rows SHALL remain unaffected
- **AND** the preference SHALL persist across relaunches

#### Scenario: Toggle uses the green switch style

- **WHEN** the user looks at the Settings form
- **THEN** the "Show Sonnet usage" toggle SHALL render with `GreenSwitchStyle()` like every other toggle in the form

#### Scenario: Default is on for existing users

- **WHEN** an existing user upgrades to the new build
- **THEN** the Sonnet row SHALL be visible on first launch without any setting change required
