## 1. ViewModel — Toggle Persistence

- [x] 1.1 Add `var showSonnetWindow: Bool = true` to `UsageViewModel`, with `didSet` persisting to `UserDefaults` under `"showSonnetWindow"` (guarded by the existing `isInitialized` pattern).
- [x] 1.2 Load the saved value in `UsageViewModel.init()` using `UserDefaults.standard.object(forKey: "showSonnetWindow") as? Bool ?? true`.

## 2. Popover — Render the Sonnet Row

- [x] 2.1 In `MenuBarView.usageWindows(_:)`, after the existing `ForEach(usage.allWindows, ...)` loop, add a conditional block:
  - if `viewModel.showSonnetWindow` and `usage.sevenDaySonnet != nil`, render a `UsageWindowView` with `title = String(localized: "7-Day Sonnet")`, `window = usage.sevenDaySonnet!`, `paceRate = nil`, `projectedHours = nil`, `scale = s`, `paceRateUnit = viewModel.paceRateUnit`, `isStale = viewModel.isWindowStale(sonnetWindow)`.
- [x] 2.2 Verify the Extra Usage block continues to render after the Sonnet row.
- [x] 2.3 Confirm `UsageResponse.allWindows` is **not** modified (so `MenuBarWindow` enum and the menu bar window picker are untouched).

## 3. Settings UI

- [x] 3.1 In `SettingsView`'s Display section, add a `Toggle("Show Sonnet usage", isOn: $viewModel.showSonnetWindow)` with `.toggleStyle(GreenSwitchStyle())`. Place it adjacent to the existing "Show pace in Usage tab" toggle.
- [x] 3.2 Confirm the toggle is only shown when `viewModel.isAuthenticated == true` (consistent with other Display section toggles).

## 4. Localization

- [x] 4.1 Add to `Localizable.xcstrings`:
  - `"7-Day Sonnet"` (en) / `"Sonnet 7 días"` (es)
  - `"Show Sonnet usage"` (en) / `"Mostrar uso de Sonnet"` (es)

## 5. Verification

- [x] 5.1 Run `make run`. Sign in with a Max account. Confirm three rows visible in order: 5-Hour, 7-Day, 7-Day Sonnet. _(Build succeeded; app launched. UI confirmation pending user check.)_
- [ ] 5.2 Toggle "Show Sonnet usage" off in Settings — the row disappears immediately. Toggle on — it returns. Quit and relaunch — the toggle state persists.
- [ ] 5.3 Confirm the Sonnet row shows percentage + progress bar + reset countdown, and **no** pace line, **no** outlook line.
- [ ] 5.4 Confirm `UsageResponse.allWindows` and `MenuBarWindow` remain unchanged: the menu bar window picker in Settings still offers only "5-Hour" and "7-Day".
- [ ] 5.5 Run with Spanish locale (`defaults write com.claudetracker.app AppleLanguages '(es)' && make run`) and confirm both new strings localize. Reset with `defaults delete com.claudetracker.app AppleLanguages` afterwards.
