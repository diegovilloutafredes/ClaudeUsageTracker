import SwiftUI

/// The preferences window, opened via the Settings menu item or the "Settings" link in the popover.
struct SettingsView: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        let sf = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w  = (sf.width / 3).rounded()

        Form {
            accountSection
            displaySection
            paceSection
            notificationsSection
            refreshSection
        }
        .formStyle(.grouped)
        .frame(minWidth: w, idealWidth: w, maxWidth: w, maxHeight: .infinity)
        .background(SettingsWindowPositioner(targetWidth: w))
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
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

            HStack {
                if let update = viewModel.availableUpdate {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("v\(update.version) available")
                        .font(.subheadline)
                    Spacer()
                    Link("Download", destination: update.releaseURL)
                        .font(.subheadline)
                } else {
                    Button(viewModel.isCheckingForUpdates ? "Checking…" : "Check for Updates") {
                        viewModel.checkForUpdates()
                    }
                    .disabled(viewModel.isCheckingForUpdates)
                }
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Unofficial tool — not affiliated with or endorsed by Anthropic. May break if Anthropic changes their web API.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

            HStack(spacing: 10) {
                Text("Popup size")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Slider(value: $viewModel.popupScale, in: 0.75...1.5, step: 0.05)
                Text("\(Int((viewModel.popupScale * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            Toggle("Show charts tab", isOn: $viewModel.showChartsTab)
                .toggleStyle(GreenSwitchStyle())

            Toggle("Show pace indicator", isOn: $viewModel.showPace)
                .toggleStyle(GreenSwitchStyle())

            if viewModel.showPace {
                HStack(spacing: 10) {
                    Text("Rate window")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Picker("", selection: $viewModel.paceHistoryMinutes) {
                        Text("5m").tag(5.0)
                        Text("10m").tag(10.0)
                        Text("15m").tag(15.0)
                        Text("30m").tag(30.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.leading, 20)
            }
        }
    }

    // MARK: - Pace Alerts

    private var paceSection: some View {
        Section {
            Toggle("Notify when approaching limit", isOn: $viewModel.notifyPace)
                .toggleStyle(GreenSwitchStyle())

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
                            .toggleStyle(GreenSwitchStyle())
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
                    .toggleStyle(GreenSwitchStyle())
                Toggle("7-Day window resets",  isOn: $viewModel.notify7Day)
                    .toggleStyle(GreenSwitchStyle())
            }

            Divider()
                .listRowInsets(EdgeInsets())

            Group {
                Toggle("Toast near menu bar", isOn: $viewModel.notifyToast)
                    .toggleStyle(GreenSwitchStyle())

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
                            .toggleStyle(GreenSwitchStyle())
                    }
                    .padding(.leading, 20)
                }

                Toggle("Sound",                      isOn: $viewModel.notifySound)
                    .toggleStyle(GreenSwitchStyle())
                Toggle("System notification banner", isOn: $viewModel.notifyBanner)
                    .toggleStyle(GreenSwitchStyle())
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
            LabeledContent("Poll every") {
                HStack(spacing: 10) {
                    Slider(value: $viewModel.refreshInterval, in: 1...60, step: 1)
                    Text("\(Int(viewModel.refreshInterval))s")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Green Switch Toggle Style

/// Custom toggle style that renders an always-green switch regardless of the system
/// accent color or SwiftUI environment tint. Uses a drawn capsule+circle so no
/// native NSSwitch environment plumbing is involved — immune to Form cell isolation.
private struct GreenSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            ZStack {
                Capsule()
                    .fill(configuration.isOn ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, x: 0, y: 1)
                    .frame(width: 18, height: 18)
                    .offset(x: configuration.isOn ? 8 : -8)
            }
            .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

// MARK: - Window Positioner

/// Captures the exact NSWindow that hosts SettingsView so we can position it
/// relative to the screen without relying on NSApp.keyWindow, which could be
/// any window (e.g. the Login window) if focus changed between onAppear and the
/// async dispatch.
private struct SettingsWindowPositioner: NSViewRepresentable {
    let targetWidth: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window, let screen = NSScreen.main else { return }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            window.title = String(format: String(localized: "Settings · v%@"), version)
            let sf  = screen.frame
            let mbh = sf.maxY - screen.visibleFrame.maxY
            let x   = (sf.midX - targetWidth / 2).rounded()
            window.setFrame(CGRect(x: x, y: sf.minY, width: targetWidth, height: sf.height - mbh), display: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
