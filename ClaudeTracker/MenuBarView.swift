import SwiftUI
import Charts

/// The popover content shown when the user clicks the menu bar icon.
struct MenuBarView: View {
    var viewModel: UsageViewModel
    @Environment(\.openSettings) private var openSettings

    @AppStorage("selectedTab") private var selectedTab = 0
    @State private var contentHeight: CGFloat = 0
    private let baseWidth: CGFloat = 312
    private var s: CGFloat { CGFloat(viewModel.popupScale) }
    private func sf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * s, weight: weight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17 * s) {
            header
            if let update = viewModel.availableUpdate {
                updateBanner(update)
            }
            if viewModel.isAuthenticated && viewModel.showChartsTab {
                tabSelector
            }
            if selectedTab == 1 && viewModel.isAuthenticated && viewModel.showChartsTab {
                chartsContent
            } else {
                content
            }
            Divider()
            footer
        }
        .padding(19 * s)
        .frame(width: baseWidth * s)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            contentHeight = newHeight
        }
        .background(PopoverResizer(height: contentHeight))
        .onChange(of: viewModel.showChartsTab) { _, enabled in
            if !enabled { selectedTab = 0 }
        }
    }

    // MARK: - Update Banner

    @ViewBuilder
    private func updateBanner(_ update: UpdateInfo) -> some View {
        HStack(spacing: 8 * s) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.green)
                .font(sf(13))
                .accessibilityHidden(true)
            Text("v\(update.version) available")
                .font(sf(11, .semibold))
            Spacer()
            Group {
                switch viewModel.updateDownloadState {
                case .idle:
                    if update.downloadURL != nil {
                        Button("Install") { viewModel.downloadAndInstall() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.green)
                    } else {
                        Link("Download", destination: update.releaseURL)
                    }
                case .downloading:
                    HStack(spacing: 4 * s) {
                        ProgressView().controlSize(.small)
                        Text("Downloading…").foregroundStyle(.secondary)
                    }
                case .installing:
                    HStack(spacing: 4 * s) {
                        ProgressView().controlSize(.small)
                        Text("Installing…").foregroundStyle(.secondary)
                    }
                case .failed:
                    Link("Download", destination: update.releaseURL)
                }
            }
            .font(sf(11))
        }
        .padding(.horizontal, 10 * s)
        .padding(.vertical, 7 * s)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8 * s))
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

    // MARK: - Tab Selector

    private var tabSelector: some View {
        HStack(spacing: 1 * s) {
            tabButton("Usage", tag: 0)
            tabButton("Charts", tag: 1)
        }
        .padding(2 * s)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7 * s))
        .frame(maxWidth: .infinity)
    }

    private func tabButton(_ label: LocalizedStringKey, tag: Int) -> some View {
        Button { selectedTab = tag } label: {
            Text(label)
                .font(sf(11, selectedTab == tag ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4 * s)
                .background(
                    selectedTab == tag ? Color.primary.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5 * s)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            .tint(.accentColor)

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
        if viewModel.isDataStale {
            Label("Window reset — refreshing…", systemImage: "arrow.clockwise")
                .font(sf(11))
                .foregroundStyle(.secondary)
        } else if let error = viewModel.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(sf(11))
                .foregroundStyle(.orange)
        }

        VStack(alignment: .leading, spacing: 17 * s) {
            ForEach(usage.allWindows, id: \.0) { windowKey, window in
                windowRow(windowKey: windowKey, window: window)
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

    private func windowRow(windowKey: MenuBarWindow, window: UsageWindow) -> some View {
        let windowIsStale = viewModel.isWindowStale(window)
        let suppressPace = window.utilization >= 100 || windowIsStale
        let pace = (viewModel.showPace && !suppressPace) ? viewModel.pace(for: windowKey.rawValue) : nil
        return UsageWindowView(
            title: windowKey.label,
            window: window,
            paceRate: pace?.rate,
            projectedHours: pace?.projectedHours,
            scale: s,
            paceRateUnit: viewModel.paceRateUnit,
            isStale: windowIsStale
        )
    }

    // MARK: - Charts

    @AppStorage("chartTimeRange") private var chartTimeRange: ChartTimeRange = .oneDay
    @State private var selectedTime: Date?

    @ViewBuilder
    private var chartsContent: some View {
        let now = Date()
        let cutoff = now.addingTimeInterval(-chartTimeRange.hours * 3600)
        let xDomain = cutoff...now
        let visible = viewModel.usageHistory.filter { $0.timestamp >= cutoff }

        VStack(alignment: .leading, spacing: 16 * s) {
            timeRangePicker
            if visible.isEmpty {
                Text("No data for this period")
                    .font(sf(12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16 * s)
            } else {
                VStack(alignment: .leading, spacing: 22 * s) {
                    windowCharts(
                        title: "5-Hour", utilKeyPath: \.fiveHour, paceKeyPath: \.fiveHourPace,
                        history: visible, xDomain: xDomain, selectedTime: $selectedTime,
                        window: viewModel.usage?.fiveHour, windowDuration: 5 * 3600,
                        currentPaceRate: viewModel.pace(for: "five_hour")?.rate
                    )
                    Divider()
                    windowCharts(
                        title: "7-Day", utilKeyPath: \.sevenDay, paceKeyPath: \.sevenDayPace,
                        history: visible, xDomain: xDomain, selectedTime: $selectedTime,
                        window: viewModel.usage?.sevenDay, windowDuration: 7 * 24 * 3600,
                        currentPaceRate: viewModel.pace(for: "seven_day")?.rate
                    )
                }
            }
        }
    }

    private var timeRangePicker: some View {
        HStack(spacing: 1 * s) {
            ForEach(ChartTimeRange.allCases, id: \.self) { range in
                Button { chartTimeRange = range } label: {
                    Text(range.rawValue)
                        .font(sf(11, chartTimeRange == range ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4 * s)
                        .background(
                            chartTimeRange == range ? Color.primary.opacity(0.1) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5 * s)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2 * s)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7 * s))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func windowCharts(
        title: String,
        utilKeyPath: KeyPath<UsageDataPoint, Double?>,
        paceKeyPath: KeyPath<UsageDataPoint, Double?>,
        history: [UsageDataPoint],
        xDomain: ClosedRange<Date>,
        selectedTime: Binding<Date?>,
        window: UsageWindow? = nil,
        windowDuration: TimeInterval = 5 * 3600,
        currentPaceRate: Double? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 14 * s) {
            Text(LocalizedStringKey(title))
                .font(sf(11, .semibold))
            miniChart(
                label: "Utilization",
                filtered: history,
                keyPath: utilKeyPath,
                domain: 0...100,
                xDomain: xDomain,
                selectedTime: selectedTime,
                formatLabel: { "\(Int($0))%" }
            )
            miniChart(
                label: "Pace",
                filtered: history,
                keyPath: paceKeyPath,
                domain: nil,
                xDomain: xDomain,
                selectedTime: selectedTime,
                formatLabel: { viewModel.paceRateUnit.format($0) }
            )
            if let w = window {
                projectionChart(
                    allHistory: viewModel.usageHistory,
                    utilKeyPath: utilKeyPath,
                    window: w,
                    paceRate: currentPaceRate,
                    windowDuration: windowDuration,
                    selectedTime: selectedTime
                )
            }
        }
    }

    private func forecastAccentColor(paceRate: Double?, lastVal: Double, lastDate: Date?, resetDate: Date) -> Color {
        guard let rate = paceRate, lastVal < 100, lastDate != nil else { return .secondary }
        let projHrs = (100.0 - lastVal) / rate
        let hrsToReset = max(resetDate.timeIntervalSinceNow / 3600, 0)
        if hrsToReset == 0 || projHrs >= hrsToReset { return .secondary }
        if projHrs >= hrsToReset * 0.8 { return urgencyColor(0.7) }
        return urgencyColor(1.0)
    }

    @ViewBuilder
    private func projectionChart(
        allHistory: [UsageDataPoint],
        utilKeyPath: KeyPath<UsageDataPoint, Double?>,
        window: UsageWindow,
        paceRate: Double?,
        windowDuration: TimeInterval,
        selectedTime: Binding<Date?>
    ) -> some View {
        if let resetDate = window.resetsAtDate {
            let windowStart = resetDate.addingTimeInterval(-windowDuration)
            let pairs: [(Date, Double)] = allHistory
                .filter { $0.timestamp >= windowStart }
                .compactMap { dp in
                    guard let v = dp[keyPath: utilKeyPath] else { return nil }
                    return (dp.timestamp, v)
                }
            let lastDate = pairs.last?.0
            let lastVal = pairs.last?.1 ?? window.utilization
            let projEnd: Date? = lastDate.flatMap { ld -> Date? in
                guard let rate = paceRate, lastVal < 100 else { return nil }
                return ld.addingTimeInterval((100.0 - lastVal) / rate * 3600)
            }
            let xMax = [resetDate, projEnd].compactMap { $0 }.max() ?? resetDate
            let accentColor = forecastAccentColor(paceRate: paceRate, lastVal: lastVal, lastDate: lastDate, resetDate: resetDate)
            let span = xMax.timeIntervalSince(windowStart)
            let xFmt: Date.FormatStyle = span < 25 * 3600
                ? .dateTime.hour().minute()
                : .dateTime.month(.abbreviated).day()
            let hovered: (Date, Double)? = selectedTime.wrappedValue.flatMap { t in
                (windowStart...xMax).contains(t)
                    ? pairs.min(by: { abs($0.0.timeIntervalSince(t)) < abs($1.0.timeIntervalSince(t)) })
                    : nil
            }
            let hoveredLabel: String? = hovered.map { t, v in
                let windowDurationSecs = resetDate.timeIntervalSince(windowStart)
                let expectedPct = windowDurationSecs > 0
                    ? min(max(t.timeIntervalSince(windowStart) / windowDurationSecs * 100, 0), 100)
                    : 0
                let timeStr = span < 25 * 3600
                    ? t.formatted(.dateTime.hour().minute())
                    : t.formatted(.dateTime.month(.abbreviated).day())
                return "actual \(Int(v))%  expected \(Int(expectedPct))%  \(timeStr)"
            }

            VStack(alignment: .leading, spacing: 7 * s) {
                HStack {
                    Text("Forecast")
                        .font(sf(10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let label = hoveredLabel {
                        Text(label)
                            .font(sf(9))
                            .foregroundStyle(.secondary)
                    } else if let rate = paceRate {
                        Text("pace \(viewModel.paceRateUnit.format(rate))")
                            .font(sf(9))
                            .foregroundStyle(.secondary)
                    }
                }
                if pairs.count < 2 {
                    Text("Collecting…")
                        .font(sf(9))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 60 * s)
                } else {
                    forecastChartBody(
                        pairs: pairs, lastDate: lastDate, lastVal: lastVal, projEnd: projEnd,
                        windowStart: windowStart, resetDate: resetDate, xMax: xMax,
                        accentColor: accentColor, xFmt: xFmt, selectedTime: selectedTime
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func forecastChartBody(
        pairs: [(Date, Double)],
        lastDate: Date?,
        lastVal: Double,
        projEnd: Date?,
        windowStart: Date,
        resetDate: Date,
        xMax: Date,
        accentColor: Color,
        xFmt: Date.FormatStyle,
        selectedTime: Binding<Date?>
    ) -> some View {
        Chart {
            LineMark(x: .value("Time", windowStart), y: .value("Usage", 0.0), series: .value("s", "expected"))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            LineMark(x: .value("Time", resetDate), y: .value("Usage", 100.0), series: .value("s", "expected"))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                AreaMark(x: .value("Time", pair.0), y: .value("Usage", pair.1))
                    .foregroundStyle(Color.secondary.opacity(0.12))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", pair.0), y: .value("Usage", pair.1), series: .value("s", "actual"))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            if let ld = lastDate, let pe = projEnd {
                LineMark(x: .value("Time", ld), y: .value("Usage", lastVal), series: .value("s", "extrapolated"))
                    .foregroundStyle(accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                LineMark(x: .value("Time", pe), y: .value("Usage", 100.0), series: .value("s", "extrapolated"))
                    .foregroundStyle(accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            if let t = selectedTime.wrappedValue, (windowStart...xMax).contains(t) {
                RuleMark(x: .value("Selected", t))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYScale(domain: 0...105)
        .chartXScale(domain: windowStart...xMax)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel(format: xFmt).font(.system(size: 8 * s))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .stride(by: 25)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))%").font(.system(size: 8 * s))
                    }
                }
            }
        }
        .frame(height: 60 * s)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let frame = geo[plotFrame]
                            let x = location.x - frame.origin.x
                            if let date = proxy.value(atX: x, as: Date.self) {
                                selectedTime.wrappedValue = date
                            }
                        case .ended:
                            selectedTime.wrappedValue = nil
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func miniChart(
        label: String,
        filtered: [UsageDataPoint],
        keyPath: KeyPath<UsageDataPoint, Double?>,
        domain: ClosedRange<Double>?,
        xDomain: ClosedRange<Date>,
        selectedTime: Binding<Date?>,
        formatLabel: @escaping (Double) -> String
    ) -> some View {
        let values: [Double] = filtered.compactMap { $0[keyPath: keyPath] }
        let peak = values.max() ?? 0
        let avg = values.isEmpty ? 0.0 : values.reduce(0, +) / Double(values.count)
        let color: Color = urgencyColor(min((values.last ?? 0) / 100.0, 1.0))
        let span = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
        let xFormat: Date.FormatStyle = span < 25 * 3600
            ? .dateTime.hour().minute()
            : .dateTime.month(.abbreviated).day()
        let hovered: (Date, Double)? = {
            guard let t = selectedTime.wrappedValue else { return nil }
            let pairs = filtered.compactMap { dp -> (Date, Double)? in
                guard let v = dp[keyPath: keyPath] else { return nil }
                return (dp.timestamp, v)
            }
            return pairs.min(by: { abs($0.0.timeIntervalSince(t)) < abs($1.0.timeIntervalSince(t)) })
        }()
        let displayValue = hovered?.1 ?? (values.last ?? 0)
        let nowLabel: String = {
            if let (t, v) = hovered {
                let timeStr = span < 25 * 3600
                    ? t.formatted(.dateTime.hour().minute())
                    : t.formatted(.dateTime.month(.abbreviated).day())
                return "@ \(formatLabel(v))  \(timeStr)"
            }
            return "now \(formatLabel(displayValue))"
        }()

        VStack(alignment: .leading, spacing: 7 * s) {
            HStack {
                Text(LocalizedStringKey(label))
                    .font(sf(10))
                    .foregroundStyle(.secondary)
                Spacer()
                if !values.isEmpty {
                    Text("\(nowLabel)  pk \(formatLabel(peak))  avg \(formatLabel(avg.rounded()))")
                        .font(sf(9))
                        .foregroundStyle(.secondary)
                }
            }
            if values.count < 2 {
                Text("Collecting…")
                    .font(sf(9))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 50 * s)
            } else {
                Chart {
                    ForEach(filtered) { dp in
                        if let v = dp[keyPath: keyPath] {
                            AreaMark(
                                x: .value("Time", dp.timestamp),
                                y: .value(label, v)
                            )
                            .foregroundStyle(color.opacity(0.15))
                            .interpolationMethod(.monotone)
                            LineMark(
                                x: .value("Time", dp.timestamp),
                                y: .value(label, v)
                            )
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.monotone)
                        }
                    }
                    if let t = selectedTime.wrappedValue, xDomain.contains(t) {
                        RuleMark(x: .value("Selected", t))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartYScale(domain: domain ?? (0...max(values.max().map { $0 * 1.2 } ?? 1, 1)))
                .chartXScale(domain: xDomain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.secondary.opacity(0.2))
                        AxisValueLabel(format: xFormat)
                            .font(.system(size: 8 * s))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.secondary.opacity(0.25))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(formatLabel(v)).font(.system(size: 8 * s))
                            }
                        }
                    }
                }
                .frame(height: 60 * s)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let frame = geo[plotFrame]
                                    let x = location.x - frame.origin.x
                                    if let date = proxy.value(atX: x, as: Date.self) {
                                        selectedTime.wrappedValue = date
                                    }
                                case .ended:
                                    selectedTime.wrappedValue = nil
                                }
                            }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                openSettings()
            } label: {
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

// MARK: - Popover Resizer

/// Forces the MenuBarExtra NSPanel to match the SwiftUI content height whenever it changes.
/// SwiftUI's fixedSize modifier alone does not resize the panel after the first render, and
/// updateNSView is only called when the struct's stored properties change — so height must
/// be passed explicitly to guarantee a call on every tab switch.
private struct PopoverResizer: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard height > 10 else { return }
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            guard abs(window.frame.height - height) > 1 else { return }
            var frame = window.frame
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

// MARK: - Chart Time Range

private enum ChartTimeRange: String, CaseIterable {
    case oneHour    = "1h"
    case fiveHours  = "5h"
    case oneDay     = "24h"
    case sevenDays  = "7d"
    case thirtyDays = "30d"

    var hours: Double {
        switch self {
        case .oneHour:    return 1
        case .fiveHours:  return 5
        case .oneDay:     return 24
        case .sevenDays:  return 168
        case .thirtyDays: return 720
        }
    }
}

// MARK: - Usage Window View

/// A single rate-limit window row: title, utilization percentage, progress bar, reset countdown, and pace.
struct UsageWindowView: View {
    let title: String
    let window: UsageWindow
    let paceRate: Double?
    let projectedHours: Double?
    let scale: CGFloat
    var paceRateUnit: PaceRateUnit = .perHour
    var isStale: Bool = false

    private func sf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack {
                Text(title)
                    .font(sf(12, .bold))
                Spacer()
                Text(isStale ? "0%" : "\(Int(window.utilization))%")
                    .font(.system(size: 12 * scale, weight: .bold).monospacedDigit())
                    .foregroundStyle(isStale ? Color.secondary : window.utilizationColor)
            }

            ProgressView(value: isStale ? 0.0 : window.utilizationFraction)
                .tint(isStale ? Color.secondary : window.utilizationColor)

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
                paceOutlookLine()
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func paceOutlookLine() -> some View {
        if let proj = projectedHours, proj > 0,
           let resetDate = window.resetsAtDate {
            let hrs = resetDate.timeIntervalSinceNow / 3600
            if hrs > 0 {
                let (icon, text, color) = paceOutlook(proj: proj, hoursToReset: hrs)
                HStack(spacing: 4) {
                    Image(systemName: icon).accessibilityHidden(true)
                    Text(text)
                }
                .font(sf(11))
                .foregroundStyle(color)
            }
        }
    }

    private func paceOutlook(proj: Double, hoursToReset: Double) -> (String, LocalizedStringKey, Color) {
        let seed = abs(Int(window.resetsAtDate?.timeIntervalSince1970 ?? 0))

        if proj >= hoursToReset {
            let messages: [LocalizedStringKey] = [
                "On track — resets before limit",
                "You're good — resets in time",
                "All clear — window resets first",
                "Safe — usage resets before full",
                "No rush — plenty of time left",
            ]
            return ("checkmark.circle", messages[seed % messages.count], Color.secondary)
        } else if proj >= hoursToReset * 0.8 {
            let messages: [LocalizedStringKey] = [
                "Getting close — may hit limit",
                "Pace is high — watch your usage",
                "Caution — cutting it close",
                "Almost at the edge — ease up",
                "Trending toward the limit",
            ]
            return ("exclamationmark.circle", messages[seed % messages.count], urgencyColor(0.7))
        } else {
            let early = hoursToReset - proj
            let timeStr = early < 1
                ? "~\(max(1, Int(early * 60)))m"
                : "~\(Int(early.rounded()))h"
            let messages: [LocalizedStringKey] = [
                "Will hit limit \(timeStr) before reset",
                "Runs out \(timeStr) before reset",
                "On pace to fill \(timeStr) early",
                "Full \(timeStr) before window resets",
            ]
            return ("exclamationmark.triangle.fill", messages[seed % messages.count], urgencyColor(1.0))
        }
    }

    private func paceLine(rate: Double) -> some View {
        let urgency: Double = {
            guard let proj = projectedHours, proj > 0,
                  let resetDate = window.resetsAtDate else { return 0 }
            let hoursToReset = resetDate.timeIntervalSinceNow / 3600
            guard hoursToReset > 0 else { return 0 }
            return min(hoursToReset / proj, 1.0)
        }()

        let rateText = paceRateUnit.format(rate, prefix: true)
        let projText: String? = projectedHours.flatMap { h in
            guard h < 24 else { return nil }
            if h < 1 { return String(format: String(localized: "· full in %dm"), max(1, Int(h * 60))) }
            let hrs = Int(h)
            let mins = Int((h - Double(hrs)) * 60)
            return mins > 0
                ? String(format: String(localized: "· full in %dh %dm"), hrs, mins)
                : String(format: String(localized: "· full in %dh"), hrs)
        }

        return HStack(spacing: 4) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .accessibilityHidden(true)
            Text([rateText, projText].compactMap { $0 }.joined(separator: " "))
        }
        .font(sf(11))
        .foregroundStyle(urgency > 0 ? urgencyColor(urgency) : Color.secondary)
    }
}
