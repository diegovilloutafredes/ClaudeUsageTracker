import SwiftUI

struct MenuBarView: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            Divider()
            footer
        }
        .padding()
        .frame(width: 320)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Claude Usage")
                .font(.headline)
            Spacer()
            if let sub = viewModel.accountInfo?.subscriptionLabel {
                Text(sub)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.purple)
            }
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !viewModel.isAuthenticated {
            emptyState
        } else if let usage = viewModel.usage {
            usageWindows(usage)
        } else if let error = viewModel.error {
            errorView(error)
        } else {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Not signed in")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                LoginWindowController.shared.open(
                    apiService: viewModel.apiService,
                    onSessionFound: viewModel.handleSessionFound
                )
            } label: {
                Label("Sign in to Claude", systemImage: "globe")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Text("Opens Claude in a browser window.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func usageWindows(_ usage: UsageResponse) -> some View {
        if let error = viewModel.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        ForEach(usage.allWindows, id: \.0) { title, window in
            UsageWindowView(title: title, window: window)
        }

        if let extra = usage.extraUsage, extra.isEnabled {
            extraUsageView(extra)
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 8) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.subheadline)

            Button("Sign in again") {
                LoginWindowController.shared.open(
                    apiService: viewModel.apiService,
                    onSessionFound: viewModel.handleSessionFound
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func extraUsageView(_ extra: ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Extra Usage")
                .font(.subheadline.bold())
            if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                Text(String(format: "$%.2f / $%.2f", used, limit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let lastUpdated = viewModel.lastUpdated {
                Text("Updated \(lastUpdated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Text("Settings")
                    .font(.caption)
            }
            .buttonStyle(.link)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}

// MARK: - Usage Window View

struct UsageWindowView: View {
    let title: String
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline.bold())
                Spacer()
                Text("\(Int(window.utilization))%")
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(window.utilizationColor)
            }

            ProgressView(value: window.utilizationFraction)
                .tint(window.utilizationColor)

            if let resetDate = window.resetsAtDate {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .accessibilityHidden(true)
                    Text("Resets \(resetDate, style: .relative)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
