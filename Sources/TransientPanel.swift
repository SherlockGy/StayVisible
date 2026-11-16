import AppKit

/// A transient UI surface only. Hiding it never changes the keep-awake session.
final class TransientPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    private var deactivateObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private weak var statusButton: NSStatusBarButton?
    private var pointerIsOverStatusButton: Bool {
        guard let button = statusButton, let window = button.window else { return false }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return rect.contains(NSEvent.mouseLocation)
    }
    static func shouldDeferDismissal(overStatus: Bool, mouseGesture: Bool) -> Bool {
        overStatus && mouseGesture
    }
    private func dismissOutsideInteraction(mouseGesture: Bool) {
        // A status-item click can deactivate the app BEFORE its mouse-up action.
        // Let that action toggle the still-visible panel instead of hiding first.
        guard !Self.shouldDeferDismissal(overStatus: pointerIsOverStatusButton, mouseGesture: mouseGesture) else { return }
        orderOut(nil)
    }
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false // Dismissal is controlled below, not NSPanel's implicit path.
        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            // Hover alone is not a click: Cmd-Tab must dismiss even over the icon.
            self?.dismissOutsideInteraction(mouseGesture: NSEvent.pressedMouseButtons != 0)
        }
    }
    func toggle(relativeTo button: NSStatusBarButton? = nil) {
        if isVisible { orderOut(nil) }
        else { present(relativeTo: button) }
    }
    func present(relativeTo button: NSStatusBarButton? = nil) {
        statusButton = button
        if let button, let anchor = button.window {
            let rect = anchor.convertToScreen(button.convert(button.bounds, to: nil))
            let bounds = anchor.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? rect
            let x = max(bounds.minX, min(rect.midX - frame.width / 2, bounds.maxX - frame.width))
            setFrameOrigin(NSPoint(x: x, y: rect.minY - frame.height - 6))
        }
        if outsideClickMonitor == nil {
            // Exclude the anchor geometrically too: menu-bar dispatch can involve
            // system processes, and app deactivation is a separate event path.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismissOutsideInteraction(mouseGesture: true)
            }
        }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    override func orderOut(_ sender: Any?) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        super.orderOut(sender)
    }
    override func close() { orderOut(nil) }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
    }
}
