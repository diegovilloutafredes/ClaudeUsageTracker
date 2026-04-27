import SwiftUI

/// The preferences window, opened via the Settings menu item or the "Settings" link in the popover.
struct SettingsView: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        Form {
            accountSection
            menuBarSection
            notificationsSection
            refreshSection
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 580)
    }

    // MARK: - Sections

    private var accountSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Account").font(.headline)

                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(viewModel.isAuthenticated ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                        .accessibilityHidden(true)

                    if let info = viewModel.accountInfo {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(info.displayName).font(.subheadline)
                                if let sub = info.subscriptionLabel {
                                    Text(sub)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.purple.opacity(0.15), in: Capsule())
                                        .foregroundStyle(Color.purple)
                                }
                            }
                            Text(info.emailAddress).font(.caption).foregroundStyle(.secondary)
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
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var menuBarSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Menu Bar Display").font(.headline)

                Picker("Show in menu bar:", selection: $viewModel.menuBarWindow) {
                    ForEach(MenuBarWindow.allCases) { window in
                        Text(window.label).tag(window)
                    }
                }
                .pickerStyle(.menu)

                Text("Which usage window to display in the menu bar")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var notificationsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Notifications").font(.headline)

                Group {
                    Text("Windows to watch").font(.caption).foregroundStyle(.secondary)
                    Toggle("5-Hour window resets", isOn: $viewModel.notify5Hour)
                    Toggle("7-Day window resets",  isOn: $viewModel.notify7Day)
                }

                Divider()

                Group {
                    Text("How to notify").font(.caption).foregroundStyle(.secondary)
                    Toggle("Toast near menu bar", isOn: $viewModel.notifyToast)

                    if viewModel.notifyToast {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("Duration")
                                    .font(.caption)
                                    .foregroundStyle(viewModel.toastPermanent ? .tertiary : .secondary)
                                Slider(value: $viewModel.toastDuration, in: 1...30, step: 1)
                                    .disabled(viewModel.toastPermanent)
                                Text(viewModel.toastPermanent ? "∞" : "\(Int(viewModel.toastDuration))s")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(viewModel.toastPermanent ? .tertiary : .secondary)
                                    .frame(width: 28, alignment: .trailing)
                            }
                            Toggle("Stay until dismissed", isOn: $viewModel.toastPermanent)
                                .font(.callout)
                        }
                        .padding(.leading, 22)
                    }

                    Toggle("Sound",                     isOn: $viewModel.notifySound)
                    Toggle("System notification banner", isOn: $viewModel.notifyBanner)
                }

                Divider()

                HStack(spacing: 12) {
                    Button("Test notifications") {
                        viewModel.sendTestNotification()
                    }
                    .disabled(!viewModel.notifyToast && !viewModel.notifySound && !viewModel.notifyBanner)

                    Text("Fires all enabled channels with a simulated 5-Hour reset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var refreshSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Refresh Interval").font(.headline)

                HStack {
                    Slider(value: $viewModel.refreshInterval, in: 1...60, step: 1)
                    Text("\(Int(viewModel.refreshInterval))s")
                        .font(.body.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }

                Text("How often to check usage (1–60 seconds)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
