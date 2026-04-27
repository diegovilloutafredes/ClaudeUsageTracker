import AppKit
import SwiftUI

/// Displays a floating toast notification near the top-right corner of the screen.
///
/// The toast is a borderless, non-activating `NSPanel` with a transparent background so
/// the SwiftUI `RoundedRectangle` material fills the visible area. Using `NSPanel` rather
/// than an `NSWindow` prevents the notification from stealing keyboard focus or appearing
/// in the application switcher.
///
/// Exact positioning at the menu bar icon is not possible through the `MenuBarExtra` API —
/// the panel is placed at a fixed offset from the screen's top-right corner instead.
@MainActor
final class ToastWindowController {
    static let shared = ToastWindowController()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// Presents a toast, replacing any currently visible one.
    ///
    /// - Parameters:
    ///   - title: Bold headline text.
    ///   - message: Supporting detail shown below the title.
    ///   - duration: Total visible time in seconds before the toast fades out. Ignored when `permanent` is `true`.
    ///   - permanent: When `true`, the toast stays on screen until the user taps the close button.
    func show(title: String, message: String, duration: Double, permanent: Bool) {
        dismissTask?.cancel()
        panel?.close()

        let toastWidth: CGFloat = 300
        let toastHeight: CGFloat = 76

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.alphaValue = 0

        let view = ToastView(title: title, message: message, onDismiss: { [weak self] in
            self?.dismiss()
        })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight)
        newPanel.contentView = hosting

        let menuBarH = NSStatusBar.system.thickness
        let screenFrame = NSScreen.main?.frame ?? .zero
        let x = screenFrame.maxX - toastWidth - 24
        let y = screenFrame.maxY - menuBarH - toastHeight - 6
        newPanel.setFrame(NSRect(x: x, y: y, width: toastWidth, height: toastHeight), display: false)

        newPanel.orderFront(nil)
        panel = newPanel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            newPanel.animator().alphaValue = 1
        }

        guard !permanent else { return }

        let fadeDuration = 0.3
        dismissTask = Task { [weak self] in
            // Sleep for (duration - fadeDuration) so the total on-screen time equals `duration`.
            try? await Task.sleep(for: .seconds(max(0, duration - fadeDuration)))
            guard !Task.isCancelled else { return }
            self?.fadeAndClose(over: fadeDuration)
        }
    }

    private func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        fadeAndClose(over: 0.2)
    }

    private func fadeAndClose(over seconds: Double) {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = seconds
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.close()
            Task { @MainActor in self.panel = nil }
        })
    }
}

private struct ToastView: View {
    let title: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(4)
    }
}
