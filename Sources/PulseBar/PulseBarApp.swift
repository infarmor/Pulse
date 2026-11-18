import AppKit
import Darwin
import PulseBarCore
import SwiftUI

@main
@MainActor
final class PulseBarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let controller = VisualizerController()
    private var statusItem: NSStatusItem?
    private var hostingView: StatusItemHostingView<StatusBarPillView>?
    /// When the current/last close started (transient close fires on the very mouse-down that
    /// should not reopen it).
    private var popoverCloseStartedAt: Date = .distantPast
    private var popoverIsClosing = false
    private var reopenAfterClose = false
    /// Invisible window just under the status item that the popover is anchored to.
    /// Anchoring to the status bar button itself makes macOS draw a gray "selected" plate
    /// around the item (merged with the popover arrow) for as long as the popover is open.
    private var popoverAnchorWindow: NSWindow?
    private var popover: NSPopover?
    private var signalSources: [DispatchSourceSignal] = []
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var screenObservers: [NSObjectProtocol] = []
    private var displayObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        installWorkspaceObservers()
        installDisplayObservers()
        installSignalHandlers()

        controller.onPillVisibilityShouldUpdate = { [weak self] visible in
            guard let self else { return }
            // Never hide the item out from under an open menu.
            self.statusItem?.isVisible = visible || self.popover?.isShown == true
        }
        controller.onPillSizeChange = { [weak self] size in
            self?.statusItem?.length = size.metrics.statusItemWidth
        }

        controller.start()
        installMenuBarHeightTracking()

        // Dev hook: `open Pulse.app --args --show-menu` opens the menu without clicking.
        if ProcessInfo.processInfo.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.togglePopover()
            }
        }
    }

    /// Keeps `controller.menuBarHeight` in sync with the status item window (differs per display).
    private func installMenuBarHeightTracking() {
        let update: @MainActor () -> Void = { [weak self] in
            guard let self, let window = self.statusItem?.button?.window else { return }
            let height = Double(window.frame.height)
            pulseLog.notice("status item frame \(window.frame.debugDescription, privacy: .public)")
            if height > 0, abs(height - self.controller.menuBarHeight) > 0.5 {
                self.controller.menuBarHeight = height
                pulseLog.notice("menu bar height -> \(height, privacy: .public)")
            }
        }
        DispatchQueue.main.async { update() }
        let names: [Notification.Name] = [
            NSApplication.didChangeScreenParametersNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didResizeNotification
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { update() }
            }
            screenObservers.append(token)
        }
    }

    /// Relaunching the app (Finder, Spotlight, `open`) brings a hidden capsule back and opens the
    /// menu, so "hide when nothing is playing" can never lock the user out.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.isVisible = true
        if popover?.isShown != true {
            togglePopover()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
        removeWorkspaceObservers()
    }

    // MARK: - Status Bar Setup

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: controller.settings.pillSize.metrics.statusItemWidth)
        if let button = item.button {
            button.title = ""
            button.image = nil
            button.setButtonType(.momentaryChange)
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.focusRingType = .none
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            let hosting = StatusItemHostingView(rootView: StatusBarPillView(controller: controller))
            // Size comes from constraints; skip per-frame intrinsic-size recomputation.
            hosting.sizingOptions = []
            hosting.onLeftClick = { [weak self] in self?.togglePopover() }
            hosting.onRightClick = { [weak self] in self?.showQuickContextMenu() }
            hosting.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: button.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
            hostingView = hosting
        }
        statusItem = item
    }

    private func setupPopover() {
        let rootView = PlayerPopoverView(
            controller: controller,
            onQuit: { [weak self] in
                self?.quitSafely()
            }
        )
        let hostingController = NSHostingController(rootView: rootView)
        let pop = NSPopover()
        // Demo/screenshot mode keeps the menu open even if another app takes focus.
        pop.behavior = DemoMode.isEnabled ? .applicationDefined : .transient
        pop.animates = true
        pop.delegate = self
        pop.contentViewController = hostingController
        popover = pop
    }

    // MARK: - Actions & Popover Lifecycle

    @objc private func handleStatusItemClick(_ sender: AnyObject?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showQuickContextMenu()
            return
        }
        togglePopover()
    }

    private func togglePopover() {
        guard let popover else { return }
        if Date().timeIntervalSince(popoverCloseStartedAt) < 0.25 {
            // This very click already closed the transient popover; don't reopen it.
            return
        }
        if popoverIsClosing {
            // Clicked during the close animation: reopen as soon as it finishes.
            reopenAfterClose = true
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let popover, let button = statusItem?.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let anchor = positionPopoverAnchor() {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Places a 1 pt tall, click-through window right below the status item and returns its view.
    private func positionPopoverAnchor() -> NSView? {
        guard let itemWindow = statusItem?.button?.window else { return nil }
        let itemFrame = itemWindow.frame
        let anchorFrame = NSRect(x: itemFrame.minX, y: itemFrame.minY - 1, width: itemFrame.width, height: 1)

        let window: NSWindow
        if let existing = popoverAnchorWindow {
            window = existing
        } else {
            let panel = NSPanel(
                contentRect: anchorFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .statusBar
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            popoverAnchorWindow = panel
            window = panel
        }
        window.setFrame(anchorFrame, display: false)
        window.orderFrontRegardless()
        return window.contentView
    }

    private func showQuickContextMenu() {
        guard let statusItem else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        }

        let menu = NSMenu()
        let playTitle = controller.track.state == .playing ? "Пауза" : "Воспроизвести"
        menu.addItem(withTitle: playTitle, action: #selector(menuTogglePlayPause), keyEquivalent: "")
        menu.addItem(withTitle: "Следующий трек", action: #selector(menuNextTrack), keyEquivalent: "")
        menu.addItem(withTitle: "Предыдущий трек", action: #selector(menuPreviousTrack), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Открыть Apple Music", action: #selector(menuOpenMusic), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выход", action: #selector(menuQuit), keyEquivalent: "q")

        for item in menu.items {
            item.target = self
        }

        // Pop the menu up ourselves (not via the button) so no selection plate is drawn.
        if let window = statusItem.button?.window {
            let frame = window.frame
            menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.minY - 4), in: nil)
        } else {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }
    }

    @objc private func menuTogglePlayPause() {
        controller.togglePlayPause()
    }

    @objc private func menuNextTrack() {
        controller.nextTrack()
    }

    @objc private func menuPreviousTrack() {
        controller.previousTrack()
    }

    @objc private func menuOpenMusic() {
        controller.openAppleMusic()
    }

    @objc private func menuQuit() {
        quitSafely()
    }

    func popoverDidShow(_ notification: Notification) {
        controller.isPopoverOpen = true
    }

    func popoverWillClose(_ notification: Notification) {
        popoverCloseStartedAt = Date()
        popoverIsClosing = true
    }

    func popoverDidClose(_ notification: Notification) {
        popoverIsClosing = false
        if reopenAfterClose {
            reopenAfterClose = false
            DispatchQueue.main.async { [weak self] in self?.showPopover() }
        }
        popoverAnchorWindow?.orderOut(nil)
        controller.isPopoverOpen = false
        statusItem?.isVisible = controller.shouldShowPill
    }

    private func quitSafely() {
        controller.stop()
        NSApp.terminate(nil)
    }

    // MARK: - System Observers

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.controller.handleSystemWillSleep()
            }
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.controller.handleSystemDidWake()
            }
        }
    }

    private func installDisplayObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, false),
            (NSWorkspace.screensDidWakeNotification, true),
            (NSWorkspace.sessionDidResignActiveNotification, false),
            (NSWorkspace.sessionDidBecomeActiveNotification, true)
        ]
        for (name, active) in pairs {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.controller.setDisplayActive(active)
                }
            }
            displayObservers.append(token)
        }
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver {
            center.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            center.removeObserver(wakeObserver)
        }
        displayObservers.forEach(center.removeObserver)
        displayObservers.removeAll()
        screenObservers.forEach(NotificationCenter.default.removeObserver)
        screenObservers.removeAll()
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.quitSafely()
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
