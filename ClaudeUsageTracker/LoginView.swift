import SwiftUI
import WebKit

// MARK: - Login Window Controller

final class LoginWindowController {
    static let shared = LoginWindowController()
    private var window: NSWindow?

    func open(apiService: ClaudeAPIService, onSessionFound: @escaping (String) -> Void) {
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
        window.title = "Sign in to Claude"
        window.contentView = NSHostingView(rootView: loginView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }
}

// MARK: - Login View

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

struct WebViewWrapper: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
