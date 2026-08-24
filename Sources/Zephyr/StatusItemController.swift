import AppKit
import SwiftUI
import Combine
import ZephyrKit

extension Notification.Name {
    static let openZephyrSettings = Notification.Name("com.bence.zephyr.openSettings")
}

/// Owns the menu bar item: the spinning glyph, the inline readout, the popover
/// and the right-click menu.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {

    private let state: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var animationTimer: Timer?
    private var angle: CGFloat = 0
    private var cancellables: Set<AnyCancellable> = []
    private var settingsWindow: NSWindow?
    private var panelWindow: NSWindow?

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()

        state.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        state.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openZephyrSettings)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.openSettings() }
            .store(in: &cancellables)

        startAnimation()
        refresh()
    }

    // MARK: Setup

    private func configureButton() {
        // No autosaveName on purpose. With one, AppKit stores a "preferred
        // position" that can land the item on top of the system clock, where it
        // is drawn over and effectively invisible — with the app still running
        // and reporting isVisible == true. Letting AppKit place the item fresh
        // each launch is worth more than remembering a drag.
        statusItem.isVisible = true
        guard let button = statusItem.button else {
            return
        }
        button.image = FanIcon.image(angle: 0)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Zephyr — fan control"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: ControlPanelView()
                .environmentObject(state)
        )
    }

    // MARK: Animation

    private func startAnimation() {
        animationTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceAnimation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func advanceAnimation() {
        guard state.settings.animateIcon, !reduceMotion else { return }
        let load = state.snapshot.fans.map(\.load).max() ?? 0
        guard state.maxFanRPM > 0 else { return }
        // Real RPM would be a blur; map fan load onto a readable 0.25–2.2 rev/s.
        let revolutionsPerSecond = 0.25 + load * 1.95
        angle -= CGFloat(revolutionsPerSecond) * (.pi * 2) / 15.0
        if angle < -(.pi * 2) { angle += .pi * 2 }
        statusItem.button?.image = FanIcon.image(angle: angle)
    }

    // MARK: Rendering

    private func refresh() {
        guard let button = statusItem.button else { return }

        if !state.settings.animateIcon || reduceMotion {
            button.image = FanIcon.image(angle: 0)
        }

        let temperature = state.headlineTemperature
        let rpm = state.maxFanRPM

        var text = ""
        switch state.settings.menuBarStyle {
        case .iconOnly:
            text = ""
        case .temperature:
            text = temperature.map { String(format: "%.0f°", $0) } ?? "--"
        case .rpm:
            text = rpm > 0 ? "\(Int(rpm.rounded()))" : "--"
        case .both:
            let left = temperature.map { String(format: "%.0f°", $0) } ?? "--"
            let right = rpm > 0 ? "\(Int(rpm.rounded()))" : "--"
            text = "\(left) \(right)"
        }


        if text.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .baselineOffset: 0.5,
            ]
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: attributes)
        }
    }

    // MARK: Interaction

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return togglePopover() }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            togglePopover()
        }
    }

    /// True when macOS did not place our item in the menu bar at all.
    ///
    /// The usual cause is the macOS 26 per-app menu bar allow-list: the block
    /// propagates from whatever process launched us, so being started by a
    /// disabled terminal, IDE or agent is enough. A genuinely full bar does it
    /// too. In every case NSStatusItem keeps reporting isVisible == true with a
    /// valid button frame, so only the window geometry gives it away.
    var statusItemIsUnavailable: Bool {
        guard let button = statusItem.button, let window = button.window else { return true }
        guard statusItem.isVisible, button.frame.width > 0, window.frame.width > 0 else { return true }
        guard let screen = window.screen ?? NSScreen.main else { return false }

        // An item macOS actually placed sits in the menu bar strip along the top
        // of its screen. On an oversubscribed bar it gets parked below the
        // screen instead, or pushed flush against the right edge where the
        // system's own clock and Control Center are drawn over it. Both look
        // identical to the user: no icon, no way in.
        if window.frame.maxY < screen.frame.maxY - 8 { return true }
        if window.frame.maxX >= screen.frame.maxX - 1 { return true }
        return false
    }

    /// Last resort: if there is no icon to click, the app must still be usable.
    func showPanelIfStatusItemUnavailable() {
        if ProcessInfo.processInfo.environment["ZEPHYR_DEBUG"] == "1" {
            let button = statusItem.button
            let message = """
            [zephyr] isVisible=\(statusItem.isVisible) length=\(statusItem.length) \
            buttonFrame=\(button?.frame.debugDescription ?? "nil") \
            windowFrame=\(button?.window?.frame.debugDescription ?? "nil") \
            screen=\(NSScreen.main?.frame.debugDescription ?? "nil") \
            visibleFrame=\(NSScreen.main?.visibleFrame.debugDescription ?? "nil") \
            unavailable=\(statusItemIsUnavailable) title=\(button?.attributedTitle.string ?? "nil") \
            hasImage=\(button?.image != nil)
            """
            try? (message + "\n").write(toFile: "/tmp/zephyr-debug.log", atomically: true, encoding: .utf8)
        }
        guard statusItemIsUnavailable else { return }
        state.reportMenuBarUnavailable()
        showPanelWindow()
    }

    /// Opens the panel without a click on the status item. Menu bar managers
    /// park hidden items off-screen, where a popover cannot anchor, so fall
    /// back to a floating window in that case.
    func showPanel() {
        guard !popover.isShown else { return }
        // Anchor the popover only if the item really is in the bar. If it never
        // fit, or a menu bar manager parked it off-screen, a popover has
        // nothing to attach to — fall back to the window.
        if let button = statusItem.button, let window = button.window,
           !statusItemIsUnavailable, window.frame.origin.x >= 0 {
            togglePopover()
        } else {
            showPanelWindow()
        }
    }

    func showPanelWindow() {
        if let window = panelWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: ControlPanelView().environmentObject(state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Zephyr"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.setContentSize(NSSize(width: 380, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        panelWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Zephyr — \(state.effectivePreset.name)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for preset in state.presets {
            let item = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            item.state = preset.id == state.settings.activePresetID ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let panel = NSMenuItem(title: "Open control panel in a window", action: #selector(showPanelWindowAction), keyEquivalent: "")
        panel.target = self
        menu.addItem(panel)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showPanelWindowAction() {
        showPanelWindow()
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let preset = state.presets.first(where: { $0.id == id }) else { return }
        state.select(preset: preset)
    }

    @objc func openSettings() {
        popover.performClose(nil)

        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView().environmentObject(state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Zephyr Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 940, height: 640))
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
