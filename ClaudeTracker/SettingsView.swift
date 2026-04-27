import SwiftUI

/// The preferences window, opened via the Settings menu item or the "Settings" link in the popover.
struct SettingsView: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        Form {
            accountSection
            displaySection
            paceSection
            notificationsSection
            refreshSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 700)
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(viewModel.isAuthenticated ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                if let info = viewModel.accountInfo {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(info.displayName)
                                .font(.subheadline)
                            if let sub = info.subscriptionLabel {
                                Text(sub)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.15), in: Capsule())
                                    .foregroundStyle(Color.purple)
                            }
                        }
                        Text(info.emailAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(viewModel.isAuthenticated ? "Signed in" : "Not signed in")
                        .font(.subheadline)
                }

                Spacer()

                if viewModel.isAuthenticated {
                    Button("Sign out") { viewModel.signOut() }
                } else {
                    Button("Sign in") {
                        LoginWindowController.shared.open(
                            apiService: viewModel.apiService,
                            onSessionFound: viewModel.handleSessionFound
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let error = viewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        Section("Display") {
            Picker("Menu bar window", selection: $viewModel.menuBarWindow) {
                ForEach(MenuBarWindow.allCases) { window in
                    Text(window.label).tag(window)
                }
            }

            Toggle("Show pace indicator", isOn: $viewModel.showPace)
        }
    }

    // MARK: - Pace Alerts

    private var paceSection: some View {
        Section {
            Toggle("Notify when approaching limit", isOn: $viewModel.notifyPace)

            if viewModel.notifyPace {
                HStack(spacing: 10) {
                    Text("Warn with less than")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Slider(value: $viewModel.paceWarningMinutes, in: 5...60, step: 5)
                    Text("\(Int(viewModel.paceWarningMinutes))m")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }

                if viewModel.notifyToast {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Toast duration")
                                .font(.callout)
                                .foregroundStyle(viewModel.paceToastPermanent ? .tertiary : .secondary)
                            Slider(value: $viewModel.paceToastDuration, in: 1...30, step: 1)
                                .disabled(viewModel.paceToastPermanent)
                            Text(viewModel.paceToastPermanent ? "∞" : "\(Int(viewModel.paceToastDuration))s")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(viewModel.paceToastPermanent ? .tertiary : .secondary)
                                .frame(width: 28, alignment: .trailing)
                        }
                        Toggle("Stay until dismissed", isOn: $viewModel.paceToastPermanent)
                            .font(.callout)
                    }
                    .padding(.leading, 20)
                }
            }
        } header: {
            Text("Pace Alerts")
        } footer: {
            Text("Alert when a watched window is projected to fill before it resets, based on your current consumption rate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section("Window Reset Notifications") {
            Group {
                Toggle("5-Hour window resets", isOn: $viewModel.notify5Hour)
                Toggle("7-Day window resets",  isOn: $viewModel.notify7Day)
            }

            Divider()
                .listRowInsets(EdgeInsets())

            Group {
                Toggle("Toast near menu bar", isOn: $viewModel.notifyToast)

                if viewModel.notifyToast {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Duration")
                                .font(.callout)
                                .foregroundStyle(viewModel.toastPermanent ? .tertiary : .secondary)
                            Slider(value: $viewModel.toastDuration, in: 1...30, step: 1)
                                .disabled(viewModel.toastPermanent)
                            Text(viewModel.toastPermanent ? "∞" : "\(Int(viewModel.toastDuration))s")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(viewModel.toastPermanent ? .tertiary : .secondary)
                                .frame(width: 28, alignment: .trailing)
                        }
                        Toggle("Stay until dismissed", isOn: $viewModel.toastPermanent)
                            .font(.callout)
                    }
                    .padding(.leading, 20)
                }

                Toggle("Sound",                      isOn: $viewModel.notifySound)
                Toggle("System notification banner", isOn: $viewModel.notifyBanner)
            }

            Divider()
                .listRowInsets(EdgeInsets())

            HStack(spacing: 10) {
                Button("Test") { viewModel.sendTestNotification() }
                    .disabled(!viewModel.notifyToast && !viewModel.notifySound && !viewModel.notifyBanner)
                Text("Fires all enabled channels with a simulated reset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Refresh

    private var refreshSection: some View {
        Section("Refresh Interval") {
            HStack(spacing: 10) {
                Slider(value: $viewModel.refreshInterval, in: 1...60, step: 1)
                Text("\(Int(viewModel.refreshInterval))s")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}
