import SwiftUI
import AppKit
import Combine
import WebKit
import UserNotifications

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner even when the app is frontmost; sound handled by NSSound
        completionHandler([.banner, .list])
    }
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var refreshInterval: Double = 5.0
    @Published var menuBarWindow: MenuBarWindow = .fiveHour
    @Published var usage: UsageResponse?
    @Published var error: String?
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var isAuthenticated = false
    @Published var accountInfo: AccountInfo?

    // Which windows to watch
    @Published var notify5Hour: Bool = true
    @Published var notify7Day:  Bool = false

    // Which channels to use
    @Published var notifyToast:   Bool   = true
    @Published var notifySound:   Bool   = true
    @Published var notifyBanner:  Bool   = true   // stored under key "notifyOnReset" for compat
    @Published var toastDuration: Double = 3.0
    @Published var toastPermanent: Bool  = false

    let apiService = ClaudeAPIService()
    private var timer: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var fetchTask: Task<Void, Never>?
    private var consecutiveErrors = 0
    private var previousResetsAt: [String: String] = [:]
    private var cachedMenuBarKey = ""
    private var cachedMenuBarImage = NSImage()
    private let notificationDelegate = NotificationDelegate()

    init() {
        let saved = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = saved > 0 ? saved : 5.0

        if let savedWindow = UserDefaults.standard.string(forKey: "menuBarWindow"),
           let window = MenuBarWindow(rawValue: savedWindow) {
            menuBarWindow = window
        }

        // v2: toast-only defaults (one-time migration resets existing installs)
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

    func checkExistingSession() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            let hasSession = cookies.contains { $0.name == "sessionKey" && $0.domain.contains("claude.ai") }
            DispatchQueue.main.async {
                self?.isAuthenticated = hasSession
                if hasSession { self?.startSession() }
            }
        }
    }

    func handleSessionFound(_ key: String) {
        isAuthenticated = true
        error = nil
        startSession()
    }

    func startSession() {
        Task { [weak self] in
            guard let self else { return }
            if let info = try? await apiService.fetchAccountInfo() {
                accountInfo = info
            }
            startPolling()
        }
    }

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
        apiService.clearCache()
        let store = WKWebsiteDataStore.default()
        store.httpCookieStore.getAllCookies { cookies in
            for cookie in cookies where cookie.domain.contains("claude.ai") {
                store.httpCookieStore.delete(cookie)
            }
        }
    }

    // MARK: - Polling

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

    var maxUtilization: Double {
        [usage?.fiveHour, usage?.sevenDay]
            .compactMap { $0?.utilization }
            .max() ?? 0
    }

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

    func sendTestNotification() {
        dispatchNotifications(windows: ["5-Hour Window"])
    }

    private func sendBannerNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        // No content.sound — NSSound handles audio separately

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
