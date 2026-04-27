import SwiftUI

/// The popover content shown when the user clicks the menu bar icon.
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
            Text("Claude Tracker")
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
            windowRow(title: title, window: window)
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

    private func windowRow(title: String, window: UsageWindow) -> some View {
        let key = title == "5-Hour Window" ? "five_hour" : "seven_day"
        let pace = viewModel.showPace ? viewModel.pace(for: key) : nil
        return UsageWindowView(
            title: title,
            window: window,
            paceRate: pace?.rate,
            projectedHours: pace?.projectedHours
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let lastUpdated = viewModel.lastUpdated {
                Text("Updated \(lastUpdated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.mini)
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

/// A single rate-limit window row: title, utilization percentage, progress bar, reset countdown, and pace.
struct UsageWindowView: View {
    let title: String
    let window: UsageWindow
    /// Current consumption rate in %/hr. `nil` when there is not yet enough history.
    var paceRate: Double? = nil
    /// Projected hours until the window reaches 100 % at the current rate. `nil` when unknown.
    var projectedHours: Double? = nil

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

            if let rate = paceRate {
                paceLine(rate: rate)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Shows the consumption rate and, when relevant, a projected time to full.
    ///
    /// Turns orange when the window is projected to reach 100 % before it resets,
    /// giving the user an at-a-glance signal that they should pace themselves.
    private func paceLine(rate: Double) -> some View {
        let concerning: Bool = {
            guard let proj = projectedHours, let resetDate = window.resetsAtDate else { return false }
            let hoursToReset = resetDate.timeIntervalSinceNow / 3600
            return hoursToReset > 0 && proj < hoursToReset
        }()

        let rateText = String(format: "+%.1f%%/hr", rate)
        let projText: String? = projectedHours.flatMap { h in
            guard h < 24 else { return nil }
            if h < 1 { return "· full in \(max(1, Int(h * 60)))m" }
            let hrs = Int(h)
            let mins = Int((h - Double(hrs)) * 60)
            return mins > 0 ? "· full in \(hrs)h \(mins)m" : "· full in \(hrs)h"
        }

        return HStack(spacing: 4) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .accessibilityHidden(true)
            Text([rateText, projText].compactMap { $0 }.joined(separator: " "))
        }
        .font(.caption2)
        .foregroundStyle(concerning ? Color.orange : Color.secondary)
    }
}
