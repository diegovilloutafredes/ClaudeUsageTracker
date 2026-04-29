import SwiftUI
import AppKit
import Combine
import WebKit
import UserNotifications

enum UpdateDownloadState {
    case idle
    case downloading
    case installing
    case failed(String)
}

/// Separate `NSObject` subclass required because `UNUserNotificationCenterDelegate` expects an
/// `NSObject`, and assigning `self` (a `@MainActor` class) as the delegate from a non-isolated
/// context produces a Swift concurrency compiler error.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the banner even when the app is frontmost; audio is handled separately by NSSound.
        completionHandler([.banner, .list])
    }
}

/// Central state for the app — owns API polling, UserDefaults persistence, and notification dispatch.
@MainActor
final class UsageViewModel: ObservableObject {
    @Published var refreshInterval: Double = 5.0
    @Published var availableUpdate: UpdateInfo? = nil
    @Published var isCheckingForUpdates = false
    @Published var updateDownloadState: UpdateDownloadState = .idle
    /// Which window's utilization the menu bar label tracks.
    @Published var menuBarWindow: MenuBarWindow = .fiveHour
    @Published var usage: UsageResponse?
    @Published var error: String?
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var isAuthenticated = false
    @Published var accountInfo: AccountInfo?

    // MARK: Notification preferences

    @Published var notify5Hour: Bool = true
    @Published var notify7Day:  Bool = false

    /// Stored under the key `"notifyOnReset"` in `UserDefaults` for backwards compatibility
    /// with installations that had the earlier single-toggle banner preference.
    @Published var notifyBanner:  Bool   = true
    @Published var notifyToast:   Bool   = true
    @Published var notifySound:   Bool   = true
    @Published var toastDuration: Double = 3.0
    @Published var toastPermanent: Bool  = false

    /// Whether the pace line is shown inside each window row in the popover.
    @Published var showPace: Bool = true
    /// Whether a notification fires when a watched window is projected to fill before it resets.
    @Published var notifyPace: Bool = false
    /// Threshold in minutes: fire the pace alert when projected full time drops below this value.
    @Published var paceWarningMinutes: Double = 30
    /// Toast duration for pace alerts, independent of the reset-notification toast duration.
    @Published var paceToastDuration: Double = 5.0
    /// When `true`, pace alert toasts stay on screen until dismissed by the user.
    @Published var paceToastPermanent: Bool = false
    /// Rolling history window in minutes; older samples are discarded.
    @Published var paceHistoryMinutes: Double = 15
    /// Multiplier applied to all spacing, padding, font sizes, and width in the popover.
    @Published var popupScale: Double = 1.0

    let apiService = ClaudeAPIService()
    private var timer: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var fetchTask: Task<Void, Never>?
    /// Increments on every failed fetch; drives exponential backoff in `applyBackoff()`.
    private var consecutiveErrors = 0
    /// Tracks the parsed `resetsAt` date seen in the previous fetch for each window key.
    /// A reset is inferred when the new date is > 1 hour later AND utilization drops below 5 %.
    private var previousResetsAt: [String: Date] = [:]
    /// Avoids rebuilding `menuBarImage` when neither the icon name nor the status text has changed.
    private var cachedMenuBarKey = ""
    private var cachedMenuBarImage = NSImage()
    private let notificationDelegate = NotificationDelegate()
    /// Rolling utilization history per window key, used to compute consumption pace.
    private var utilizationHistory: [String: [(Date, Double)]] = [:]
    /// Window keys for which a pace alert has already fired in the current window period.
    private var paceWarned: Set<String> = []
    /// Toast IDs for active pace alerts, keyed by window key, so they can be dismissed when pace improves.
    private var paceToastIDs: [String: UUID] = [:]
    /// Historical utilization snapshots, sampled at most once per 5 minutes, for the Charts tab.
    @Published var usageHistory: [UsageDataPoint] = []
    /// Whether the Charts tab is shown in the popover.
    @Published var showChartsTab: Bool = true
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

        notifyBanner  = UserDefaults.standard.object(forKey: "notifyOnReset")   as? Bool   ?? false
        notifySound   = UserDefaults.standard.object(forKey: "notifySound")    as? Bool   ?? false
        notifyToast   = UserDefaults.standard.object(forKey: "notifyToast")    as? Bool   ?? true
        notify5Hour   = UserDefaults.standard.object(forKey: "notify5Hour")    as? Bool   ?? true
        notify7Day    = UserDefaults.standard.object(forKey: "notify7Day")     as? Bool   ?? false
        let savedDuration = UserDefaults.standard.double(forKey: "toastDuration")
        toastDuration = savedDuration > 0 ? savedDuration : 3.0
        toastPermanent = UserDefaults.standard.object(forKey: "toastPermanent") as? Bool ?? false
        showPace       = UserDefaults.standard.object(forKey: "showPace")       as? Bool   ?? true
        notifyPace     = UserDefaults.standard.object(forKey: "notifyPace")     as? Bool   ?? false
        let savedWarning = UserDefaults.standard.double(forKey: "paceWarningMinutes")
        paceWarningMinutes = savedWarning > 0 ? savedWarning : 30
        let savedPaceDuration = UserDefaults.standard.double(forKey: "paceToastDuration")
        paceToastDuration  = savedPaceDuration > 0 ? savedPaceDuration : 5.0
        paceToastPermanent = UserDefaults.standard.object(forKey: "paceToastPermanent") as? Bool ?? false
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

        $menuBarWindow
            .dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0.rawValue, forKey: "menuBarWindow") }
            .store(in: &cancellables)

        $refreshInterval
            .dropFirst()
            .debounce(for: .seconds(0.3), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in self?.startPolling() }
            .store(in: &cancellables)

        $notifyBanner.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "notifyOnReset") }
            .store(in: &cancellables)

        $notifySound.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "notifySound") }
            .store(in: &cancellables)

        $notifyToast.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "notifyToast") }
            .store(in: &cancellables)

        $notify5Hour.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "notify5Hour") }
            .store(in: &cancellables)

        $notify7Day.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "notify7Day") }
            .store(in: &cancellables)

        $toastDuration.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "toastDuration") }
            .store(in: &cancellables)

        $toastPermanent.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "toastPermanent") }
            .store(in: &cancellables)

        $showPace.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "showPace") }
            .store(in: &cancellables)

        $notifyPace.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "notifyPace") }
            .store(in: &cancellables)

        $paceWarningMinutes.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "paceWarningMinutes") }
            .store(in: &cancellables)

        $paceToastDuration.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "paceToastDuration") }
            .store(in: &cancellables)

        $paceToastPermanent.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "paceToastPermanent") }
            .store(in: &cancellables)

        $paceHistoryMinutes.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "paceHistoryMinutes") }
            .store(in: &cancellables)

        $popupScale.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "popupScale") }
            .store(in: &cancellables)

        $showChartsTab.dropFirst().removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: "showChartsTab") }
            .store(in: &cancellables)

        UNUserNotificationCenter.current().delegate = notificationDelegate
        requestNotificationPermission()
        checkExistingSession()
        Task { try? await Task.sleep(for: .seconds(10)); checkForUpdates() }

        NSApp.publisher(for: \.effectiveAppearance)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.cachedMenuBarKey = ""
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
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

    var statusText: String {
        guard isAuthenticated else { return "–" }
        guard usage != nil else {
            return error != nil ? "!" : "…"
        }
        return "\(Int(displayedUtilization))%"
    }

    var statusIcon: String {
        let effectiveUrgency = max(displayedUtilization / 100.0, displayedWindowPaceUrgency())
        if effectiveUrgency >= 0.8 { return "exclamationmark.triangle.fill" }
        if effectiveUrgency >= 0.5 { return "bolt.badge.clock.fill" }
        return "bolt.fill"
    }

    var statusColor: NSColor {
        guard isAuthenticated, usage != nil else { return .labelColor }
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

        guard notifyBanner || notifySound || notifyToast else {
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

        if notifyToast  { ToastWindowController.shared.show(title: title, message: body, duration: toastDuration, permanent: toastPermanent) }
        if notifySound  { NSSound(named: NSSound.Name("Glass"))?.play() }
        if notifyBanner { sendBannerNotification(title: title, body: body) }
    }

    /// Triggers a test notification through all currently enabled channels using a simulated reset.
    func sendTestNotification() {
        dispatchNotifications(windows: [String(localized: "5-Hour Window")])
    }

    private func sendBannerNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        // Sound is omitted here; NSSound handles audio independently to prevent double-play
        // when both the sound and banner channels are enabled simultaneously.

        let request = UNNotificationRequest(
            identifier: "usage-reset-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    // MARK: - Private

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
                if notifyToast  { paceToastIDs[key] = ToastWindowController.shared.show(title: title, message: body, duration: paceToastDuration, permanent: paceToastPermanent) }
                if notifySound  { NSSound(named: NSSound.Name("Glass"))?.play() }
                if notifyBanner { sendBannerNotification(title: title, body: body) }
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
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "usageHistory")
        }
    }

    // MARK: - Update Check

    /// Checks GitHub Releases for a newer version and populates `availableUpdate` if found.
    /// Safe to call multiple times; debounced by `isCheckingForUpdates`.
    func checkForUpdates() {
        guard !isCheckingForUpdates else { return }
        if case .failed = updateDownloadState { updateDownloadState = .idle }
        isCheckingForUpdates = true
        Task {
            defer { isCheckingForUpdates = false }
            guard let url = URL(string: "https://api.github.com/repos/diegovilloutafredes/ClaudeTracker/releases/latest") else { return }
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let htmlUrl = json["html_url"] as? String,
                  let releaseUrl = URL(string: htmlUrl) else { return }
            let remote  = tag.trimmingCharacters(in: .init(charactersIn: "v"))
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if isNewerVersion(remote, than: current) {
                let assets = json["assets"] as? [[String: Any]]
                let zipAsset = assets?.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                let downloadURL = (zipAsset?["browser_download_url"] as? String).flatMap(URL.init)
                availableUpdate = UpdateInfo(version: remote, releaseURL: releaseUrl, downloadURL: downloadURL)
            }
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

                if directOK {
                    // Detached relaunch: wait for this process to exit, then open new version
                    let script = "#!/bin/bash\nsleep 1.5\nopen /Applications/ClaudeTracker.app\n"
                    let scriptURL = tmpBase.appendingPathComponent("relaunch.sh")
                    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/bash")
                    p.arguments = [scriptURL.path]
                    try p.run()
                    try await Task.sleep(for: .milliseconds(300))
                    NSApp.terminate(nil)
                } else {
                    // Sandbox blocked direct copy — open install.command in Terminal
                    let commandURL = extractDir.appendingPathComponent("install.command")
                    guard FileManager.default.fileExists(atPath: commandURL.path) else {
                        throw UpdateError.installationFailed
                    }
                    NSWorkspace.shared.open(commandURL)
                    try await Task.sleep(for: .seconds(2))
                    NSApp.terminate(nil)
                }
            } catch {
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
