import AppKit
import SwiftUI

@MainActor
final class FullScreenWindowPresenter: ObservableObject {
    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?
    private var escapeMonitor: Any?
    private let escapeHandler = EscapeHandler()

    func present(_ content: AnyView, onEscape: (() -> Void)? = nil) {
        escapeHandler.action = onEscape
        if let hostingController {
            hostingController.rootView = content
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(rootView: content)
        let window = EscapeFullScreenWindow(contentViewController: hostingController)
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        window.styleMask = [.borderless]
        window.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]
        window.level = .mainMenu
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.onEscape = { [weak escapeHandler] in
            escapeHandler?.action?()
        }
        window.setFrame(screen?.frame ?? .zero, display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        installEscapeMonitor(for: window)
        self.hostingController = hostingController
        self.window = window
    }

    func close() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        escapeMonitor = nil
        escapeHandler.action = nil
        window?.orderOut(nil)
        hostingController = nil
        window = nil
    }

    private func installEscapeMonitor(for window: NSWindow) {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak escapeHandler] event in
            guard event.keyCode == 53, window?.isKeyWindow == true else { return event }
            escapeHandler?.action?()
            return nil
        }
    }
}

private final class EscapeHandler {
    var action: (() -> Void)?
}

private final class EscapeFullScreenWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else {
            super.keyDown(with: event)
            return
        }
        onEscape?()
    }
}
