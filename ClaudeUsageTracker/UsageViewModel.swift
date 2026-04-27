import SwiftUI
import AppKit
import Combine
import WebKit
import UserNotifications

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

    let apiService = ClaudeAPIService()
    private var timer: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var fetchTask: Task<Void, Never>?
    /// Increments on every failed fetch; drives exponential backoff in `applyBackoff()`.
    private var consecutiveErrors = 0
    /// Tracks the `resetsAt` timestamp seen in the previous fetch for each window key.
    /// A reset is inferred when this value changes AND utilization drops below 5 %.
    private var previousResetsAt: [String: String] = [:]
    /// Avoids rebuilding `menuBarImage` when neither the icon name nor the status text has changed.
    private var cachedMenuBarKey = ""
    private var cachedMenuBarImage = NSImage()
    private let notificationDelegate = NotificationDelegate()
    /// Rolling utilization history per window key, used to compute consumption pace.
    private var utilizationHistory: [String: [(Date, Double)]] = [:]

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

        UNUserNotificationCenter.current().delegate = notificationDelegate
        requestNotificationPermission()
        checkExistingSession()
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
                usage = response
                error = nil
                lastUpdated = Date()
                consecutiveErrors = 0
            } catch let err as ClaudeAPIService.APIError {
                guard !Task.isCancelled else { return }
                consecutiveErrors += 1
                error = err.localizedDescription
                if case .unauthorized = err {
                    isAuthenticated = false
                    timer?.cancel()
                    timer = nil
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
        let util = displayedUtilization
        if util >= 80 { return "exclamationmark.triangle.fill" }
        if util >= 50 { return "bolt.badge.clock.fill" }
        return "bolt.fill"
    }

    /// Composed SF Symbol + text image used as the menu bar label.
    ///
    /// `MenuBarExtra` label blocks do not reliably render `HStack { Image; Text }` or
    /// `Label(text, systemImage:)` — the icon renders but the text is clipped or hidden.
    /// The only reliable approach is to composite both elements into a single `NSImage`
    /// with `isTemplate = true` for correct dark/light mode inversion.
    /// The result is cached until either the icon name or the text changes.
    var menuBarImage: NSImage {
        let icon = statusIcon
        let text = statusText
        let key = icon + text
        if key == cachedMenuBarKey { return cachedMenuBarImage }
        cachedMenuBarKey = key
        cachedMenuBarImage = buildMenuBarImage(iconName: icon, text: text)
        return cachedMenuBarImage
    }

    private func buildMenuBarImage(iconName: String, text: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let symbolImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) ?? NSImage()
        let symbolSize = symbolImage.size
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
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
        composed.isTemplate = true
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
           let oldTs = previousResetsAt["five_hour"],
           let newWindow = new.fiveHour,
           newWindow.resetsAt != oldTs,
           newWindow.utilization < 5 {
            resets.append("5-Hour Window")
        }

        if notify7Day,
           let oldTs = previousResetsAt["seven_day"],
           let newWindow = new.sevenDay,
           newWindow.resetsAt != oldTs,
           newWindow.utilization < 5 {
            resets.append("7-Day Window")
        }

        recordResetsAt(new)

        if !resets.isEmpty {
            dispatchNotifications(windows: resets)
        }
    }

    private func recordResetsAt(_ response: UsageResponse) {
        if let w = response.fiveHour { previousResetsAt["five_hour"] = w.resetsAt }
        if let w = response.sevenDay  { previousResetsAt["seven_day"]  = w.resetsAt }
    }

    // MARK: - Notification Dispatch

    private func dispatchNotifications(windows: [String]) {
        let title = "Claude Usage Reset"
        let body  = "\(windows.joined(separator: " & ")) reset — you're good to go!"

        if notifyToast  { ToastWindowController.shared.show(title: title, message: body, duration: toastDuration, permanent: toastPermanent) }
        if notifySound  { NSSound(named: NSSound.Name("Glass"))?.play() }
        if notifyBanner { sendBannerNotification(title: title, body: body) }
    }

    /// Triggers a test notification through all currently enabled channels using a simulated reset.
    func sendTestNotification() {
        dispatchNotifications(windows: ["5-Hour Window"])
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
        let cutoff = now.addingTimeInterval(-15 * 60)

        func append(key: String, utilization: Double?) {
            guard let utilization else { return }
            var history = utilizationHistory[key] ?? []
            if let last = history.last, utilization < last.1 - 20 {
                history = []
            }
            history.append((now, utilization))
            utilizationHistory[key] = history.filter { $0.0 >= cutoff }
        }

        append(key: "five_hour", utilization: response.fiveHour?.utilization)
        append(key: "seven_day", utilization: response.sevenDay?.utilization)
    }

    /// Returns the current consumption rate and projected time to full for a window.
    ///
    /// Requires at least two minutes of history to produce a meaningful rate.
    /// Returns `nil` when the rate is negligible (≤ 0.1 %/hr) or data is insufficient.
    ///
    /// - Parameter key: The window key — `"five_hour"` or `"seven_day"`.
    func pace(for key: String) -> (rate: Double, projectedHours: Double?)? {
        guard let history = utilizationHistory[key], history.count >= 2 else { return nil }
        let oldest = history.first!
        let newest = history.last!
        let elapsed = newest.0.timeIntervalSince(oldest.0) / 3600.0
        guard elapsed >= (2.0 / 60.0) else { return nil }
        let rate = (newest.1 - oldest.1) / elapsed
        guard rate > 0.1 else { return nil }
        let remaining = 100.0 - newest.1
        let projectedHours: Double? = remaining > 0 ? remaining / rate : nil
        return (rate, projectedHours)
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
        error = "\(base) (retry in \(Int(interval))s)"
        timer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.fetchUsage() }
    }
}
