import SwiftUI
import AppKit
import Combine
import WebKit

enum UpdateDownloadState {
    case idle
    case downloading
    case installing
    case failed(String)
}

/// Central state for the app — owns API polling, UserDefaults persistence, and notification dispatch.
@Observable @MainActor
final class UsageViewModel {
    var refreshInterval: Double = 5.0 {
        didSet {
            guard refreshInterval != oldValue else { return }
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            debounceRestartPolling()
        }
    }
    var availableUpdate: UpdateInfo? = nil
    var isCheckingForUpdates = false
    var updateDownloadState: UpdateDownloadState = .idle
    var autoUpdate: Bool = false {
        didSet {
            guard autoUpdate != oldValue else { return }
            UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate")
            schedulePeriodicUpdateCheck()
        }
    }
    /// Which window's utilization the menu bar label tracks.
    var menuBarWindow: MenuBarWindow = .fiveHour {
        didSet {
            guard menuBarWindow != oldValue else { return }
            UserDefaults.standard.set(menuBarWindow.rawValue, forKey: "menuBarWindow")
        }
    }
    var usage: UsageResponse?
    var error: String?
    var isLoading = false
    var lastUpdated: Date?
    var isAuthenticated = false
    var accountInfo: AccountInfo?

    // MARK: Notification preferences

    var notify5Hour: Bool = true {
        didSet { guard notify5Hour != oldValue else { return }; UserDefaults.standard.set(notify5Hour, forKey: "notify5Hour") }
    }
    var notify7Day: Bool = false {
        didSet { guard notify7Day != oldValue else { return }; UserDefaults.standard.set(notify7Day, forKey: "notify7Day") }
    }
    var notifyToast: Bool = true {
        didSet { guard notifyToast != oldValue else { return }; UserDefaults.standard.set(notifyToast, forKey: "notifyToast") }
    }
    var resetSoundEnabled: Bool = false {
        didSet {
            guard resetSoundEnabled != oldValue else { return }
            UserDefaults.standard.set(resetSoundEnabled, forKey: "notifySound")
            if resetSoundEnabled && isInitialized { NSSound(named: .init("Hero"))?.play() }
        }
    }
    var toastDuration: Double = 3.0 {
        didSet { guard toastDuration != oldValue else { return }; UserDefaults.standard.set(toastDuration, forKey: "toastDuration") }
    }
    var toastPermanent: Bool = false {
        didSet { guard toastPermanent != oldValue else { return }; UserDefaults.standard.set(toastPermanent, forKey: "toastPermanent") }
    }
    var paceToastEnabled: Bool = false {
        didSet { guard paceToastEnabled != oldValue else { return }; UserDefaults.standard.set(paceToastEnabled, forKey: "paceToastEnabled") }
    }
    var paceSoundEnabled: Bool = false {
        didSet {
            guard paceSoundEnabled != oldValue else { return }
            UserDefaults.standard.set(paceSoundEnabled, forKey: "paceSoundEnabled")
            if paceSoundEnabled && isInitialized { NSSound(named: .init("Basso"))?.play() }
        }
    }

    /// Whether the pace line is shown inside each window row in the popover.
    var showPace: Bool = true {
        didSet { guard showPace != oldValue else { return }; UserDefaults.standard.set(showPace, forKey: "showPace") }
    }
    /// Whether a notification fires when a watched window is projected to fill before it resets.
    var notifyPace: Bool = false {
        didSet { guard notifyPace != oldValue else { return }; UserDefaults.standard.set(notifyPace, forKey: "notifyPace") }
    }
    /// Threshold in minutes: fire the pace alert when projected full time drops below this value.
    var paceWarningMinutes: Double = 30 {
        didSet { guard paceWarningMinutes != oldValue else { return }; UserDefaults.standard.set(paceWarningMinutes, forKey: "paceWarningMinutes") }
    }
    /// Toast duration for pace alerts, independent of the reset-notification toast duration.
    var paceToastDuration: Double = 5.0 {
        didSet { guard paceToastDuration != oldValue else { return }; UserDefaults.standard.set(paceToastDuration, forKey: "paceToastDuration") }
    }
    /// When `true`, pace alert toasts stay on screen until dismissed by the user.
    var paceToastPermanent: Bool = false {
        didSet { guard paceToastPermanent != oldValue else { return }; UserDefaults.standard.set(paceToastPermanent, forKey: "paceToastPermanent") }
    }
    /// Rolling history window in minutes; older samples are discarded.
    var paceHistoryMinutes: Double = 15 {
        didSet { guard paceHistoryMinutes != oldValue else { return }; UserDefaults.standard.set(paceHistoryMinutes, forKey: "paceHistoryMinutes") }
    }
    /// Multiplier applied to all spacing, padding, font sizes, and width in the popover.
    var popupScale: Double = 1.0 {
        didSet { guard popupScale != oldValue else { return }; UserDefaults.standard.set(popupScale, forKey: "popupScale") }
    }
    /// Historical utilization snapshots, sampled at most once per 5 minutes, for the Charts tab.
    var usageHistory: [UsageDataPoint] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(usageHistory) {
                UserDefaults.standard.set(data, forKey: "usageHistory")
            }
        }
    }
    /// Whether the Charts tab is shown in the popover.
    var showChartsTab: Bool = true {
        didSet { guard showChartsTab != oldValue else { return }; UserDefaults.standard.set(showChartsTab, forKey: "showChartsTab") }
    }

    @ObservationIgnored private var isInitialized = false
    @ObservationIgnored let apiService = ClaudeAPIService()
    @ObservationIgnored private var timer: AnyCancellable?
    @ObservationIgnored private var updateCheckTimer: AnyCancellable?
    @ObservationIgnored private var appearanceCancellable: AnyCancellable?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var lastNotifiedUpdateVersion: String = ""
    /// Adaptive check interval (seconds), computed from release cadence. Clamped 4h–24h.
    private var nextCheckInterval: TimeInterval = 12 * 3600

    var updateCheckIntervalLabel: String {
        let h = (nextCheckInterval / 3600).rounded()
        if h < 24 { return "Checks every ~\(Int(h))h — on launch and wake" }
        return "Checks every ~\(max(1, Int((h / 24).rounded())))d — on launch and wake"
    }
    /// Increments on every failed fetch; drives exponential backoff in `applyBackoff()`.
    private var consecutiveErrors = 0
    /// Tracks the parsed `resetsAt` date seen in the previous fetch for each window key.
    /// A reset is inferred when the new date is > 1 hour later AND utilization drops below 5 %.
    private var previousResetsAt: [String: Date] = [:]
    /// Avoids rebuilding `menuBarImage` when neither the icon name nor the status text has changed.
    private var cachedMenuBarKey = ""
    private var cachedMenuBarImage = NSImage()
    /// Rolling utilization history per window key, used to compute consumption pace.
    private var utilizationHistory: [String: [(Date, Double)]] = [:]
    /// Window keys for which a pace alert has already fired in the current window period.
    private var paceWarned: Set<String> = []
    /// Toast IDs for active pace alerts, keyed by window key, so they can be dismissed when pace improves.
    private var paceToastIDs: [String: UUID] = [:]
    private var lastHistoryTimestamp: Date? = nil

    init() {
        let saved = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = saved > 0 ? saved : 5.0

        if let savedWindow = UserDefaults.standard.string(forKey: "menuBarWindow"),
           let window = MenuBarWindow(rawValue: savedWindow) {
            menuBarWindow = window
        }

        // Version 2 migration: resets any earlier installation that may have had sound and banner
        // enabled by default to the current toast-only defaults.
        if UserDefaults.standard.integer(forKey: "notificationDefaultsVersion") < 2 {
            UserDefaults.standard.set(false, forKey: "notifyOnReset")
            UserDefaults.standard.set(false, forKey: "notifySound")
            UserDefaults.standard.set(true,  forKey: "notifyToast")
            UserDefaults.standard.set(true,  forKey: "notify5Hour")
            UserDefaults.standard.set(false, forKey: "notify7Day")
            UserDefaults.standard.set(2, forKey: "notificationDefaultsVersion")
        }

        resetSoundEnabled = UserDefaults.standard.object(forKey: "notifySound")       as? Bool ?? false
        notifyToast       = UserDefaults.standard.object(forKey: "notifyToast")       as? Bool ?? true
        notify5Hour       = UserDefaults.standard.object(forKey: "notify5Hour")       as? Bool ?? true
        notify7Day        = UserDefaults.standard.object(forKey: "notify7Day")        as? Bool ?? false
        let savedDuration = UserDefaults.standard.double(forKey: "toastDuration")
        toastDuration  = savedDuration > 0 ? savedDuration : 3.0
        toastPermanent = UserDefaults.standard.object(forKey: "toastPermanent")       as? Bool ?? false
        showPace       = UserDefaults.standard.object(forKey: "showPace")             as? Bool ?? true
        notifyPace     = UserDefaults.standard.object(forKey: "notifyPace")           as? Bool ?? false
        let savedWarning = UserDefaults.standard.double(forKey: "paceWarningMinutes")
        paceWarningMinutes = savedWarning > 0 ? savedWarning : 30
        paceToastEnabled   = UserDefaults.standard.object(forKey: "paceToastEnabled") as? Bool ?? false
        let savedPaceDuration = UserDefaults.standard.double(forKey: "paceToastDuration")
        paceToastDuration  = savedPaceDuration > 0 ? savedPaceDuration : 5.0
        paceToastPermanent = UserDefaults.standard.object(forKey: "paceToastPermanent") as? Bool ?? false
        paceSoundEnabled   = UserDefaults.standard.object(forKey: "paceSoundEnabled") as? Bool ?? false
        let savedHistory = UserDefaults.standard.double(forKey: "paceHistoryMinutes")
        paceHistoryMinutes = savedHistory > 0 ? savedHistory : 15
        // v1: rebase — old 1.0 was the original size; new 1.0 matches old 1.1 (base constants grew ×1.1).
        // Reset any saved scale so existing users see the new default appearance unchanged.
        if UserDefaults.standard.object(forKey: "popupScaleRebased") == nil {
            UserDefaults.standard.set(1.0, forKey: "popupScale")
            UserDefaults.standard.set(1, forKey: "popupScaleRebased")
        }
        let savedPopupScale = UserDefaults.standard.double(forKey: "popupScale")
        popupScale = savedPopupScale > 0 ? savedPopupScale : 1.0

        showChartsTab = UserDefaults.standard.object(forKey: "showChartsTab") as? Bool ?? true
        if let historyData = UserDefaults.standard.data(forKey: "usageHistory"),
           let decoded = try? JSONDecoder().decode([UsageDataPoint].self, from: historyData) {
            usageHistory = decoded
        }

        autoUpdate = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? false
        lastNotifiedUpdateVersion = UserDefaults.standard.string(forKey: "lastNotifiedUpdateVersion") ?? ""

        let savedCheckInterval = UserDefaults.standard.double(forKey: "updateCheckInterval")
        if savedCheckInterval >= 4 * 3600 { nextCheckInterval = savedCheckInterval }

        isInitialized = true

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                AppLogger.shared.info("wake detected — scheduling usage fetch and update check")
                try? await Task.sleep(for: .seconds(5))
                self?.fetchUsage()
                try? await Task.sleep(for: .seconds(25))
                self?.checkForUpdates()
            }
        }

        checkExistingSession()
        Task { try? await Task.sleep(for: .seconds(10)); checkForUpdates() }
        schedulePeriodicUpdateCheck()

        appearanceCancellable = NSApp.publisher(for: \.effectiveAppearance)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.cachedMenuBarKey = ""
            }
    }

    // MARK: - Session

    /// Checks the shared WKWebView cookie store for an existing session without requiring sign-in.
    ///
    /// Called at launch so users who authenticated in a previous session bypass the sign-in prompt.
    func checkExistingSession() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            let hasSession = cookies.contains { $0.name == "sessionKey" && $0.domain.contains("claude.ai") }
            DispatchQueue.main.async {
                self?.isAuthenticated = hasSession
                if hasSession { self?.startSession() }
            }
        }
    }

    /// Called by the login flow once a session cookie has been detected.
    func handleSessionFound(_ key: String) {
        isAuthenticated = true
        error = nil
        startSession()
    }

    /// Loads account info and starts the polling timer.
    func startSession() {
        Task { [weak self] in
            guard let self else { return }
            if let info = try? await apiService.fetchAccountInfo() {
                accountInfo = info
            }
            startPolling()
        }
    }

    /// Signs out by cancelling in-flight requests, clearing all state, and deleting claude.ai cookies.
    func signOut() {
        fetchTask?.cancel()
        fetchTask = nil
        isLoading = false
        timer?.cancel()
        timer = nil
        usage = nil
        error = nil
        accountInfo = nil
        isAuthenticated = false
        previousResetsAt = [:]
        utilizationHistory = [:]
        paceWarned = []
        apiService.clearCache()
        let store = WKWebsiteDataStore.default()
        store.httpCookieStore.getAllCookies { cookies in
            for cookie in cookies where cookie.domain.contains("claude.ai") {
                store.httpCookieStore.delete(cookie)
            }
        }
    }

    // MARK: - Polling

    /// Cancels any existing timer and starts a fresh polling cycle at `refreshInterval`.
    func startPolling() {
        timer?.cancel()
        timer = nil
        consecutiveErrors = 0
        guard isAuthenticated else { return }

        fetchUsage()
        timer = Timer.publish(every: refreshInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.fetchUsage() }
    }

    /// Fetches the latest usage data, detects resets, and applies backoff on repeated failures.
    func fetchUsage() {
        guard isAuthenticated else { return }
        if isDataStale { AppLogger.shared.info("fetchUsage: refreshing stale data (resetsAt passed since last fetch)") }
        fetchTask?.cancel()
        isLoading = true
        fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await apiService.fetchUsage()
                guard !Task.isCancelled else { return }
                checkForResets(old: usage, new: response)
                recordHistory(response)
                appendDataPoint(response)
                checkPaceNotifications(response)
                usage = response
                error = nil
                lastUpdated = Date()
                consecutiveErrors = 0
            } catch let err as ClaudeAPIService.APIError {
                guard !Task.isCancelled else { return }
                consecutiveErrors += 1
                AppLogger.shared.error("fetchUsage APIError (#\(consecutiveErrors)): \(err.localizedDescription)")
                error = err.localizedDescription
                if case .unauthorized = err {
                    if consecutiveErrors > 1 {
                        isAuthenticated = false
                        timer?.cancel()
                        timer = nil
                    }
                    // First 401: mapJSError already cleared isPageReady;
                    // next poll reloads the page and retries automatically.
                } else if case .rateLimited = err {
                    applyBackoff()
                }
            } catch {
                guard !Task.isCancelled else { return }
                consecutiveErrors += 1
                AppLogger.shared.error("fetchUsage unexpected error (#\(consecutiveErrors)): \(error)")
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    // MARK: - Computed State

    /// Highest utilization across the 5-hour and 7-day windows.
    var maxUtilization: Double {
        [usage?.fiveHour, usage?.sevenDay]
            .compactMap { $0?.utilization }
            .max() ?? 0
    }

    /// Utilization of the window the user has selected for the menu bar label.
    var displayedUtilization: Double {
        guard let usage else { return 0 }
        switch menuBarWindow {
        case .fiveHour: return usage.fiveHour?.utilization ?? 0
        case .sevenDay:  return usage.sevenDay?.utilization  ?? 0
        }
    }

    /// True when the stored `usage` was fetched before a window's `resetsAt` time that has
    /// now passed — meaning the displayed utilization belongs to the previous window cycle
    /// and is definitively wrong. Clears automatically once a fresh fetch succeeds.
    var isDataStale: Bool {
        guard let usage, let lastUpdated else { return false }
        let now = Date()
        return [usage.fiveHour, usage.sevenDay].compactMap { $0 }.contains { window in
            guard let resetDate = window.resetsAtDate else { return false }
            return resetDate < now && lastUpdated < resetDate
        }
    }

    var statusText: String {
        guard isAuthenticated else { return "–" }
        guard usage != nil else { return error != nil ? "!" : "…" }
        if isDataStale { return "…" }
        return "\(Int(displayedUtilization))%"
    }

    var statusIcon: String {
        if isDataStale { return "bolt.fill" }
        let effectiveUrgency = max(displayedUtilization / 100.0, displayedWindowPaceUrgency())
        if effectiveUrgency >= 0.8 { return "exclamationmark.triangle.fill" }
        if effectiveUrgency >= 0.5 { return "bolt.badge.clock.fill" }
        return "bolt.fill"
    }

    var statusColor: NSColor {
        guard isAuthenticated, usage != nil, !isDataStale else { return .labelColor }
        let effectiveUrgency = max(displayedUtilization / 100.0, displayedWindowPaceUrgency())
        return urgencyNSColor(effectiveUrgency)
    }

    private func urgencyNSColor(_ urgency: Double) -> NSColor {
        let t = max(0, min(1, urgency))
        return NSColor(hue: 0.33 * (1 - t), saturation: 0.85, brightness: 0.9, alpha: 1.0)
    }

    private func displayedWindowPaceUrgency() -> Double {
        let key: String
        let window: UsageWindow?
        switch menuBarWindow {
        case .fiveHour: key = "five_hour"; window = usage?.fiveHour
        case .sevenDay:  key = "seven_day";  window = usage?.sevenDay
        }
        guard let paceData = pace(for: key),
              let proj = paceData.projectedHours,
              proj > 0,
              let resetDate = window?.resetsAtDate else { return 0 }
        let hoursToReset = resetDate.timeIntervalSinceNow / 3600
        guard hoursToReset > 0 else { return 0 }
        return min(hoursToReset / proj, 1.0)
    }

    /// Composed SF Symbol + text image used as the menu bar label.
    ///
    /// `MenuBarExtra` label blocks do not reliably render `HStack { Image; Text }` or
    /// `Label(text, systemImage:)` — the icon renders but the text is clipped or hidden.
    /// The only reliable approach is to composite both elements into a single `NSImage`.
    /// The result is cached until the icon, text, color, or system appearance changes.
    var menuBarImage: NSImage {
        let icon = statusIcon
        let text = statusText
        let color = statusColor
        let appearance = NSApp.effectiveAppearance.name.rawValue
        let key = icon + text + color.description + appearance
        if key == cachedMenuBarKey { return cachedMenuBarImage }
        cachedMenuBarKey = key
        cachedMenuBarImage = buildMenuBarImage(iconName: icon, text: text, color: color)
        return cachedMenuBarImage
    }

    private func buildMenuBarImage(iconName: String, text: String, color: NSColor) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color, .labelColor]))
        let symbolImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) ?? NSImage()
        let symbolSize = symbolImage.size
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let spacing: CGFloat = 3
        let totalWidth = symbolSize.width + spacing + textSize.width
        let height = max(symbolSize.height, textSize.height)
        let composed = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { rect in
            let iconY = (rect.height - symbolSize.height) / 2
            symbolImage.draw(in: NSRect(x: 0, y: iconY, width: symbolSize.width, height: symbolSize.height))
            let textY = (rect.height - textSize.height) / 2
            (text as NSString).draw(at: NSPoint(x: symbolSize.width + spacing, y: textY), withAttributes: attrs)
            return true
        }
        return composed
    }

    // MARK: - Reset Detection

    /// Compares previous `resetsAt` timestamps to the new response to detect window resets.
    ///
    /// A window is considered reset when both of the following hold:
    /// - The `resetsAt` timestamp has changed (the server issued a new window period), and
    /// - Utilization has dropped below 5 % (guards against a timestamp refresh without an actual reset).
    ///
    /// On the first fetch (`old == nil`) timestamps are recorded as a baseline without firing a notification.
    private func checkForResets(old: UsageResponse?, new: UsageResponse) {
        guard old != nil else {
            recordResetsAt(new)
            return
        }

        guard resetSoundEnabled || notifyToast else {
            recordResetsAt(new)
            return
        }

        var resets: [String] = []

        if notify5Hour,
           let oldDate = previousResetsAt["five_hour"],
           let newWindow = new.fiveHour,
           let newDate = newWindow.resetsAtDate,
           newDate.timeIntervalSince(oldDate) > 3600,
           newWindow.utilization < 5 {
            resets.append(String(localized: "5-Hour Window"))
        }

        if notify7Day,
           let oldDate = previousResetsAt["seven_day"],
           let newWindow = new.sevenDay,
           let newDate = newWindow.resetsAtDate,
           newDate.timeIntervalSince(oldDate) > 3600,
           newWindow.utilization < 5 {
            resets.append(String(localized: "7-Day Window"))
        }

        recordResetsAt(new)

        if !resets.isEmpty {
            dispatchNotifications(windows: resets)
        }
    }

    private func recordResetsAt(_ response: UsageResponse) {
        if let w = response.fiveHour, let d = w.resetsAtDate { previousResetsAt["five_hour"] = d }
        if let w = response.sevenDay,  let d = w.resetsAtDate { previousResetsAt["seven_day"]  = d }
    }

    // MARK: - Notification Dispatch

    private func dispatchNotifications(windows: [String]) {
        let title = String(localized: "Claude Usage Reset")
        let body  = String(format: String(localized: "%@ reset — you're good to go!"), windows.joined(separator: " & "))

        if notifyToast       { ToastWindowController.shared.show(title: title, message: body, duration: toastDuration, permanent: toastPermanent) }
        if resetSoundEnabled { NSSound(named: .init("Hero"))?.play() }
    }

    /// Triggers a test reset notification through all currently enabled channels.
    func sendTestNotification() {
        dispatchNotifications(windows: [String(localized: "5-Hour Window")])
    }

    /// Triggers a test pace notification through all currently enabled pace channels.
    func sendTestPaceNotification() {
        let title = String(localized: "Approaching usage limit")
        let body  = String(format: String(localized: "%@ fills in %d min at %.1f%%/hr"),
                           String(localized: "5-Hour Window"), 25, 45.0)
        if paceToastEnabled { ToastWindowController.shared.show(title: title, message: body, icon: "exclamationmark.triangle.fill", iconColor: .orange, duration: paceToastDuration, permanent: paceToastPermanent) }
        if paceSoundEnabled { NSSound(named: .init("Basso"))?.play() }
    }

    // MARK: - Private

    private func debounceRestartPolling() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.startPolling()
        }
    }

    // MARK: - Pace

    /// Appends the current utilization readings to the rolling history for each window.
    ///
    /// Readings older than 15 minutes are discarded. If utilization for a window drops by
    /// more than 20 percentage points compared to the last recorded value, the history is
    /// cleared first — this handles window resets, which drop utilization back to near zero.
    private func recordHistory(_ response: UsageResponse) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-paceHistoryMinutes * 60)

        func append(key: String, utilization: Double?) {
            guard let utilization else { return }
            var history = utilizationHistory[key] ?? []
            if let last = history.last, utilization < last.1 - 20 {
                history = []
                paceWarned.remove(key)
                if let tid = paceToastIDs.removeValue(forKey: key) {
                    ToastWindowController.shared.dismiss(id: tid)
                }
            }
            history.append((now, utilization))
            utilizationHistory[key] = history.filter { $0.0 >= cutoff }
        }

        append(key: "five_hour", utilization: response.fiveHour?.utilization)
        append(key: "seven_day", utilization: response.sevenDay?.utilization)
    }

    /// Fires a pace alert through all enabled channels when a watched window is on track to
    /// fill before it resets. Each window can only trigger one alert per window period;
    /// the warned flag resets automatically when utilization drops (i.e. the window resets).
    private func checkPaceNotifications(_ response: UsageResponse) {
        guard notifyPace else {
            paceWarned.removeAll()
            return
        }

        let candidates: [(key: String, name: String, watched: Bool)] = [
            ("five_hour", String(localized: "5-Hour Window"), notify5Hour),
            ("seven_day",  String(localized: "7-Day Window"),  notify7Day),
        ]

        for (key, name, watched) in candidates {
            guard watched else { continue }
            let paceData = pace(for: key)
            let isConcerning = paceData.flatMap(\.projectedHours).map { $0 * 60 < paceWarningMinutes } ?? false
            if isConcerning, !paceWarned.contains(key), let pd = paceData, let projHours = pd.projectedHours {
                paceWarned.insert(key)
                let minsLeft = max(1, Int(projHours * 60))
                let title = String(localized: "Approaching usage limit")
                let body  = String(format: String(localized: "%@ fills in %d min at %.1f%%/hr"), name, minsLeft, pd.rate)
                if paceToastEnabled { paceToastIDs[key] = ToastWindowController.shared.show(title: title, message: body, icon: "exclamationmark.triangle.fill", iconColor: .orange, duration: paceToastDuration, permanent: paceToastPermanent) }
                if paceSoundEnabled { NSSound(named: .init("Basso"))?.play() }
            } else if !isConcerning, paceWarned.contains(key) {
                // Pace improved past the threshold — dismiss the alert even if set to permanent.
                if let tid = paceToastIDs.removeValue(forKey: key) {
                    ToastWindowController.shared.dismiss(id: tid)
                }
                if paceData == nil { paceWarned.remove(key) }
            }
        }
    }

    /// Returns the current consumption rate and projected time to full for a window.
    ///
    /// Requires at least two minutes of history to produce a meaningful rate.
    /// Returns `nil` when the rate is negligible (≤ 0.1 %/hr) or data is insufficient.
    ///
    /// - Parameter key: The window key — `"five_hour"` or `"seven_day"`.
    func pace(for key: String) -> (rate: Double, projectedHours: Double?)? {
        guard let history = utilizationHistory[key] else { return nil }
        return computePace(history: history)
    }

    private func appendDataPoint(_ response: UsageResponse) {
        let now = Date()
        if let last = lastHistoryTimestamp, now.timeIntervalSince(last) < 300 { return }
        lastHistoryTimestamp = now
        let point = UsageDataPoint(
            timestamp: now,
            fiveHour: response.fiveHour?.utilization,
            sevenDay: response.sevenDay?.utilization,
            fiveHourPace: pace(for: "five_hour")?.rate,
            sevenDayPace: pace(for: "seven_day")?.rate
        )
        let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
        var history = usageHistory.filter { $0.timestamp >= cutoff }
        history.append(point)
        if history.count > 8640 { history = Array(history.suffix(8640)) }
        usageHistory = history
    }

    // MARK: - Update Check

    /// Fetches the last 10 GitHub releases, checks for a newer version, and updates the adaptive
    /// check interval from the release cadence. Safe to call multiple times — debounced by
    /// `isCheckingForUpdates`.
    func checkForUpdates() {
        guard !isCheckingForUpdates else { return }
        if case .failed = updateDownloadState { updateDownloadState = .idle }
        isCheckingForUpdates = true
        Task {
            defer { isCheckingForUpdates = false }
            guard let url = URL(string: "https://api.github.com/repos/diegovilloutafredes/ClaudeTracker/releases?per_page=10") else { return }
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let latest = releases.first,
                  let tag = latest["tag_name"] as? String,
                  let htmlUrl = latest["html_url"] as? String,
                  let releaseUrl = URL(string: htmlUrl) else { return }

            let remote  = tag.trimmingCharacters(in: .init(charactersIn: "v"))
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if isNewerVersion(remote, than: current) {
                let assets = latest["assets"] as? [[String: Any]]
                let zipAsset = assets?.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                let downloadURL = (zipAsset?["browser_download_url"] as? String).flatMap(URL.init)
                availableUpdate = UpdateInfo(version: remote, releaseURL: releaseUrl, downloadURL: downloadURL)

                // Only notify once per discovered version (persisted across restarts)
                if lastNotifiedUpdateVersion != remote {
                    lastNotifiedUpdateVersion = remote
                    UserDefaults.standard.set(remote, forKey: "lastNotifiedUpdateVersion")
                    if autoUpdate, downloadURL != nil {
                        if case .idle = updateDownloadState { triggerAutoInstall() }
                    } else {
                        ToastWindowController.shared.show(
                            title: String(localized: "Update available"),
                            message: String(format: String(localized: "v%@ is ready — open Settings to install"), remote),
                            icon: "arrow.up.circle.fill",
                            iconColor: .green,
                            duration: 12,
                            permanent: false
                        )
                    }
                }
            }

            let computed = computeCheckInterval(from: releases)
            if computed != nextCheckInterval {
                nextCheckInterval = computed
                UserDefaults.standard.set(computed, forKey: "updateCheckInterval")
                AppLogger.shared.info("update check interval adjusted to \(Int(computed / 3600))h based on release cadence")
                if autoUpdate { schedulePeriodicUpdateCheck() }
            }
        }
    }

    /// Derives a check interval from the average gap between the last N release dates.
    /// Clamped to [4h, 24h]; defaults to 12h when history is insufficient.
    private func computeCheckInterval(from releases: [[String: Any]]) -> TimeInterval {
        let fmt = ISO8601DateFormatter()
        let dates = releases.compactMap { r -> Date? in
            guard let s = r["published_at"] as? String else { return nil }
            return fmt.date(from: s)
        }.sorted(by: >)
        guard dates.count >= 2 else { return 12 * 3600 }
        var gaps: [TimeInterval] = []
        for i in 0..<(dates.count - 1) {
            let gap = dates[i].timeIntervalSince(dates[i + 1])
            if gap > 0 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return 12 * 3600 }
        let avg = gaps.reduce(0, +) / Double(gaps.count)
        return max(4 * 3600, min(24 * 3600, avg * 0.5))
    }

    private func schedulePeriodicUpdateCheck() {
        updateCheckTimer?.cancel()
        updateCheckTimer = nil
        guard autoUpdate else { return }
        updateCheckTimer = Timer.publish(every: nextCheckInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkForUpdates() }
    }

    private func triggerAutoInstall() {
        guard let update = availableUpdate, update.downloadURL != nil else { return }
        let msg = String(format: String(localized: "v%@ found — installing in ~10s"), update.version)
        ToastWindowController.shared.show(
            title: String(localized: "Update available"),
            message: msg,
            icon: "arrow.down.circle.fill",
            iconColor: .green,
            duration: 12,
            permanent: false
        )
        Task {
            try? await Task.sleep(for: .seconds(10))
            downloadAndInstall()
        }
    }

    func downloadAndInstall() {
        guard let update = availableUpdate, let downloadURL = update.downloadURL else { return }
        guard case .idle = updateDownloadState else { return }
        updateDownloadState = .downloading

        let tmpBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClaudeTrackerUpdate")

        Task {
            do {
                try? FileManager.default.removeItem(at: tmpBase)
                try FileManager.default.createDirectory(at: tmpBase, withIntermediateDirectories: true)

                // Download ZIP
                let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
                let zipURL = tmpBase.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: tempURL, to: zipURL)

                // Extract on background thread (waitUntilExit blocks)
                let extractDir = tmpBase.appendingPathComponent("extracted")
                let appURL: URL = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
                            let unzip = Process()
                            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                            unzip.arguments = ["-o", zipURL.path, "-d", extractDir.path]
                            try unzip.run()
                            unzip.waitUntilExit()
                            guard unzip.terminationStatus == 0 else {
                                cont.resume(throwing: UpdateError.extractionFailed); return
                            }
                            let items = (try? FileManager.default.contentsOfDirectory(
                                at: extractDir, includingPropertiesForKeys: nil)) ?? []
                            if let app = items.first(where: { $0.pathExtension == "app" }) {
                                cont.resume(returning: app)
                            } else {
                                cont.resume(throwing: UpdateError.appNotFound)
                            }
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }

                updateDownloadState = .installing

                // Try direct install (works when sandbox is not enforced)
                let dest = URL(fileURLWithPath: "/Applications/ClaudeTracker.app")
                let directOK: Bool = await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? FileManager.default.removeItem(at: dest)
                        cont.resume(returning: (try? FileManager.default.copyItem(at: appURL, to: dest)) != nil)
                    }
                }

                // Fail gracefully if copy was blocked (e.g. sandbox in signed dev builds).
                // Never open install.command or terminate without a successful install.
                guard directOK else { throw UpdateError.installationFailed }

                // Relaunch: try a detached shell script first (works in unsigned release builds).
                // Fall back to NSWorkspace.open when Process is sandbox-blocked.
                let relaunchScript = "#!/bin/bash\nsleep 1.5\nopen \"/Applications/ClaudeTracker.app\"\n"
                let scriptURL = tmpBase.appendingPathComponent("relaunch.sh")
                var usedScript = false
                if (try? relaunchScript.write(to: scriptURL, atomically: true, encoding: .utf8)) != nil {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/bash")
                    p.arguments = [scriptURL.path]
                    usedScript = (try? p.run()) != nil
                }
                try await Task.sleep(for: .milliseconds(300))
                if !usedScript {
                    NSWorkspace.shared.open(dest)
                    try await Task.sleep(for: .milliseconds(500))
                }
                NSApp.terminate(nil)
            } catch {
                AppLogger.shared.error("auto-update failed: \(error)")
                updateDownloadState = .failed(error.localizedDescription)
            }
        }
    }

    private enum UpdateError: LocalizedError {
        case extractionFailed, appNotFound, installationFailed
        var errorDescription: String? {
            switch self {
            case .extractionFailed:   return String(localized: "Failed to extract update")
            case .appNotFound:        return String(localized: "Update package is invalid")
            case .installationFailed: return String(localized: "Installation failed")
            }
        }
    }

    /// Replaces the polling timer with one firing at an escalating interval.
    ///
    /// The backoff adds 10 s per consecutive error up to a cap of 60 s above the base `refreshInterval`.
    /// The error message is updated to show the effective retry delay.
    private func applyBackoff() {
        timer?.cancel()
        let backoff = min(Double(consecutiveErrors) * 10, 60)
        let interval = refreshInterval + backoff
        let base = (error ?? "Error").components(separatedBy: " (retry in ").first ?? "Error"
        error = String(format: String(localized: "%@ (retry in %ds)"), base, Int(interval))
        timer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.fetchUsage() }
    }
}
