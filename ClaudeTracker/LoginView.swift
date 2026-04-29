import SwiftUI
import WebKit

// MARK: - Login Window Controller

/// Manages the lifecycle of the browser-based sign-in window.
///
/// Reuses a single `NSWindow` across calls — clicking "Sign in" while the window is already
/// open brings it to front rather than creating a duplicate.
@MainActor
final class LoginWindowController {
    static let shared = LoginWindowController()
    private var window: NSWindow?
    private var popupWindow: NSWindow?
    private var popupWindowObserver: NSObjectProtocol?

    /// Opens the sign-in window, or focuses it if already visible.
    ///
    /// - Parameters:
    ///   - apiService: Provides the `WKWebView` to embed and the cookie-polling API.
    ///   - onSessionFound: Called on the main thread once a session cookie is detected.
    ///     The window closes automatically 1.5 s after this callback fires to let the
    ///     user see the success state before it disappears.
    func open(apiService: ClaudeAPIService, onSessionFound: @escaping (String) -> Void) {
        apiService.onPopupRequested = { [weak self] popupView, _ in
            self?.showPopup(webView: popupView)
        }
        apiService.onPopupDismissed = { [weak self] in
            self?.closePopup()
        }

        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let loginView = LoginView(
            apiService: apiService,
            onSessionFound: { key in
                onSessionFound(key)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.close()
                }
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Sign in to Claude")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: loginView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    func close() {
        closePopup()
        window?.close()
        window = nil
    }

    private func showPopup(webView: WKWebView) {
        let popup = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 650),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        popup.title = String(localized: "Sign in")
        popup.isReleasedWhenClosed = false
        popup.contentView = webView
        if let parent = window {
            popup.center()
            parent.addChildWindow(popup, ordered: .above)
        } else {
            popup.center()
        }
        popup.makeKeyAndOrderFront(nil)
        self.popupWindow = popup

        popupWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: popup,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePopup() }
        }
    }

    private func closePopup() {
        if let observer = popupWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            popupWindowObserver = nil
        }
        popupWindow?.close()
        popupWindow = nil
    }
}

// MARK: - Login View

/// Hosts the embedded web view and a status banner during and after sign-in.
struct LoginView: View {
    let apiService: ClaudeAPIService
    let onSessionFound: (String) -> Void
    @State private var found = false

    var body: some View {
        VStack(spacing: 0) {
            if found {
                successBanner
            } else {
                infoBanner
            }
            WebViewWrapper(webView: apiService.webView)
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            apiService.loadLoginPage()
            apiService.startCookiePolling { key in
                found = true
                onSessionFound(key)
            }
        }
        .onDisappear {
            apiService.stopCookiePolling()
        }
    }

    private var infoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text("Sign in to your Claude account. The session will be captured automatically.")
                .font(.subheadline)
            Spacer()
        }
        .padding(10)
        .background(.blue.opacity(0.1))
    }

    private var successBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Signed in! Closing…")
                .font(.subheadline.bold())
            Spacer()
        }
        .padding(10)
        .background(.green.opacity(0.1))
    }
}

// MARK: - WebView Wrapper

/// Embeds the `ClaudeAPIService` web view into a SwiftUI view hierarchy.
///
/// The web view is owned by `ClaudeAPIService` and shared between the login window and the
/// hidden API context — this wrapper avoids creating a second instance.
struct WebViewWrapper: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
