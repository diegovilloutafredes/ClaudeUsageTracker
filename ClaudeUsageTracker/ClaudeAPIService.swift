import Foundation
import WebKit

@MainActor
final class ClaudeAPIService: NSObject, WKNavigationDelegate {
    let webView: WKWebView

    private var isPageReady = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var isLoadingPage = false
    private var cachedOrgId: String?
    private var cookieTimer: Timer?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        super.init()
        self.webView.navigationDelegate = self
    }

    // MARK: - Login Support

    func loadLoginPage() {
        isPageReady = false
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }

    func startCookiePolling(onFound: @escaping (String) -> Void) {
        cookieTimer?.invalidate()
        cookieTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                if let session = cookies.first(where: { $0.name == "sessionKey" && $0.domain.contains("claude.ai") }) {
                    DispatchQueue.main.async {
                        self?.cookieTimer?.invalidate()
                        self?.cookieTimer = nil
                        onFound(session.value)
                    }
                }
            }
        }
    }

    func stopCookiePolling() {
        cookieTimer?.invalidate()
        cookieTimer = nil
    }

    // MARK: - Page Readiness

    /// Loads claude.ai in the webview so fetch() calls have the correct origin.
    /// Concurrent callers all wait on the same load — no continuation is orphaned.
    func ensureReady() async throws {
        if isPageReady { return }
        try await withCheckedThrowingContinuation { continuation in
            readyWaiters.append(continuation)
            guard !isLoadingPage else { return }
            isLoadingPage = true
            if let host = webView.url?.host, host.contains("claude.ai"),
               webView.url?.path != "/login" {
                checkPageReady()
            } else {
                webView.load(URLRequest(url: URL(string: "https://claude.ai")!))
            }
        }
    }

    private func checkPageReady() {
        webView.evaluateJavaScript("document.title") { [weak self] result, _ in
            guard let self else { return }
            let title = (result as? String) ?? ""
            if title.lowercased().contains("just a moment") {
                // Still on Cloudflare challenge — wait for next didFinish
                return
            }
            self.isPageReady = true
            self.isLoadingPage = false
            self.resumeAllWaiters()
        }
    }

    private func resumeAllWaiters() {
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func failAllWaiters(with error: Error) {
        let waiters = readyWaiters
        readyWaiters = []
        isLoadingPage = false
        waiters.forEach { $0.resume(throwing: error) }
    }

    // MARK: - API Calls via WebView fetch()

    func fetchAccountInfo() async throws -> AccountInfo {
        try await ensureReady()
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                """
                const r = await fetch('/api/account', { credentials: 'include' });
                if (!r.ok) throw new Error('HTTP_' + r.status);
                return JSON.stringify(await r.json());
                """,
                contentWorld: .defaultClient
            )
        } catch {
            throw mapJSError(error)
        }
        guard let str = result as? String, let data = str.data(using: .utf8) else {
            throw APIError.invalidResponse
        }
        return try JSONDecoder().decode(AccountInfo.self, from: data)
    }

    func fetchUsage() async throws -> UsageResponse {
        try await ensureReady()

        let orgId = try await resolveOrgId()
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                """
                const r = await fetch('/api/organizations/' + orgId + '/usage', { credentials: 'include' });
                if (!r.ok) throw new Error('HTTP_' + r.status);
                return JSON.stringify(await r.json());
                """,
                arguments: ["orgId": orgId],
                contentWorld: .defaultClient
            )
        } catch {
            throw mapJSError(error)
        }

        guard let str = result as? String, let data = str.data(using: .utf8) else {
            throw APIError.invalidResponse
        }
        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    func clearCache() {
        cachedOrgId = nil
        isPageReady = false
    }

    // MARK: - Private

    private func resolveOrgId() async throws -> String {
        if let cached = cachedOrgId { return cached }

        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                """
                const r = await fetch('/api/organizations', { credentials: 'include' });
                if (!r.ok) throw new Error('HTTP_' + r.status);
                return JSON.stringify(await r.json());
                """,
                contentWorld: .defaultClient
            )
        } catch {
            throw mapJSError(error)
        }

        guard let str = result as? String, let data = str.data(using: .utf8) else {
            throw APIError.invalidResponse
        }
        let orgs = try JSONDecoder().decode([Organization].self, from: data)
        guard let id = orgs.first?.uuid else { throw APIError.noOrganization }
        cachedOrgId = id
        return id
    }

    private func mapJSError(_ error: Error) -> APIError {
        let msg = error.localizedDescription
        if msg.contains("HTTP_401") || msg.contains("HTTP_403") {
            isPageReady = false
            cachedOrgId = nil
            return .unauthorized
        }
        if msg.contains("HTTP_429") { return .rateLimited }
        if msg.contains("HTTP_") { return .httpError(msg) }
        return .networkError(msg)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !readyWaiters.isEmpty {
            checkPageReady()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failAllWaiters(with: APIError.networkError(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Ignore cancellation errors (caused by redirects)
        if (error as NSError).code == NSURLErrorCancelled { return }
        failAllWaiters(with: APIError.networkError(error.localizedDescription))
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case noOrganization
        case invalidResponse
        case unauthorized
        case rateLimited
        case httpError(String)
        case networkError(String)

        var errorDescription: String? {
            switch self {
            case .noOrganization: return "No organization found"
            case .invalidResponse: return "Invalid API response"
            case .unauthorized: return "Session expired — please sign in again"
            case .rateLimited: return "Rate limited — retrying shortly"
            case .httpError(let s): return "Server error: \(s)"
            case .networkError(let s): return "Network error: \(s)"
            }
        }
    }
}
