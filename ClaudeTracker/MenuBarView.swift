import SwiftUI

/// The popover content shown when the user clicks the menu bar icon.
struct MenuBarView: View {
    @ObservedObject var viewModel: UsageViewModel

    private let baseWidth: CGFloat = 312
    private var s: CGFloat { CGFloat(viewModel.popupScale) }
    private func sf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * s, weight: weight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17 * s) {
            header
            content
            Divider()
            footer
        }
        .padding(19 * s)
        .frame(width: baseWidth * s)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Claude Tracker")
                .font(sf(14, .semibold))
            Spacer()
            if let sub = viewModel.accountInfo?.subscriptionLabel {
                Text(sub)
                    .font(sf(10, .semibold))
                    .padding(.horizontal, 6 * s)
                    .padding(.vertical, 2 * s)
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
        VStack(spacing: 11 * s) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(sf(23))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Not signed in")
                .font(sf(12))
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
                .font(sf(11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8 * s)
    }

    @ViewBuilder
    private func usageWindows(_ usage: UsageResponse) -> some View {
        if let error = viewModel.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(sf(11))
                .foregroundStyle(.orange)
        }

        VStack(alignment: .leading, spacing: 17 * s) {
            ForEach(usage.allWindows, id: \.0) { title, window in
                windowRow(title: title, window: window)
            }
        }

        if let extra = usage.extraUsage, extra.isEnabled {
            extraUsageView(extra)
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 8 * s) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(sf(12))

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
        .padding(.vertical, 8 * s)
    }

    @ViewBuilder
    private func extraUsageView(_ extra: ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 4 * s) {
            Text("Extra Usage")
                .font(sf(12, .bold))
            if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                Text(String(format: "$%.2f / $%.2f", used, limit))
                    .font(sf(11))
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
            projectedHours: pace?.projectedHours,
            scale: s
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let lastUpdated = viewModel.lastUpdated {
                Text("Updated \(lastUpdated, style: .relative) ago")
                    .font(sf(11))
                    .foregroundStyle(.secondary)
            }
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            Spacer()
            SettingsLink {
                Text("Settings")
                    .font(sf(11))
            }
            .buttonStyle(.link)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.link)
            .font(sf(11))
        }
    }
}

// MARK: - Usage Window View

/// A single rate-limit window row: title, utilization percentage, progress bar, reset countdown, and pace.
struct UsageWindowView: View {
    let title: String
    let window: UsageWindow
    var paceRate: Double? = nil
    var projectedHours: Double? = nil
    var scale: CGFloat = 1.0

    private func sf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack {
                Text(title)
                    .font(sf(12, .bold))
                Spacer()
                Text("\(Int(window.utilization))%")
                    .font(.system(size: 12 * scale, weight: .bold).monospacedDigit())
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
                .font(sf(11))
                .foregroundStyle(.secondary)
            }

            if let rate = paceRate {
                paceLine(rate: rate)
            }
        }
        .accessibilityElement(children: .combine)
    }

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
        .font(sf(11))
        .foregroundStyle(concerning ? Color.orange : Color.secondary)
    }
}
