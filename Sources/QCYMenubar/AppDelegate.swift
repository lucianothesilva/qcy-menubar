import AppKit
import SwiftUI

/// Borderless panel that can still take key focus (so Esc-to-close works).
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the menu bar item and the LG-style popover panel with an arrow tail.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    static let panelWidth: CGFloat = 360
    static let defaultHeight: CGFloat = 636

    let model = HeadsetModel()

    private var statusItem: NSStatusItem!
    private let panel = Panel(contentRect: .zero,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
    private var host: NSHostingController<PanelShell>?
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "headphones",
                                   accessibilityDescription: "QCY H3 Control")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(toggle)
        }

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.panel.orderOut(nil) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.panel.isVisible == true {
                self?.panel.orderOut(nil)
                return nil
            }
            return event
        }

        model.startAutoConnect()

        if !CommandLine.arguments.contains("--background") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.disconnect()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return true
    }

    // MARK: - Menu bar item

    @objc private func toggle() {
        if panel.isVisible { panel.orderOut(nil) } else { show() }
    }

    // MARK: - Panel positioning

    func show() {
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main!
        let visible = screen.visibleFrame

        let top = min(anchor.minY - 3, visible.maxY - 3)
        let height = min(Self.defaultHeight, max(320, top - visible.minY - 12))
        let x = min(max(anchor.midX - Self.panelWidth / 2, visible.minX + 8),
                    visible.maxX - Self.panelWidth - 8)
        let arrowX = min(Self.panelWidth - 18, max(18, anchor.midX - x))

        let root = PanelShell(model: model, height: height, arrowX: arrowX)
        if let host {
            host.rootView = root
        } else {
            let controller = NSHostingController(rootView: root)
            host = controller
            panel.contentViewController = controller
        }

        // Screen coordinates explicitly, so AppKit cannot flip it above the menu bar.
        panel.setFrame(NSRect(x: x, y: top - height, width: Self.panelWidth, height: height),
                       display: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}
