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
    private var hostingView: PassthroughHostingView<StatusBarPillView>?
    private var popover: NSPopover?
    private var signalSources: [DispatchSourceSignal] = []
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        installWorkspaceObservers()
        installSignalHandlers()

        controller.onPillVisibilityShouldUpdate = { [weak self] visible in
            self?.statusItem?.isVisible = visible
        }

        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
        removeWorkspaceObservers()
    }

    // MARK: - Status Bar Setup

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 54)
        if let button = item.button {
            button.title = ""
            button.image = nil
            button.setButtonType(.momentaryChange)
            button.focusRingType = .none
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            let hosting = PassthroughHostingView(rootView: StatusBarPillView(controller: controller))
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
        pop.behavior = .transient
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
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
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

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
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

    func popoverDidClose(_ notification: Notification) {
        controller.isPopoverOpen = false
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

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver {
            center.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            center.removeObserver(wakeObserver)
        }
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
