//
//  boringNotchApp.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import Sparkle
import SwiftUI

@main
struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Environment(\.openWindow) var openWindow

    let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        // Initialize the settings window controller with the updater controller
        SettingsWindowController.shared.setUpdaterController(updaterController)
    }

    var body: some Scene {
        MenuBarExtra("boring.notch", systemImage: "sparkle", isInserted: $showMenuBarIcon) {
            Button("Settings") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            CheckForUpdatesView(updater: updaterController.updater)
            Divider()
            Button("Restart Boring Notch") {
                ApplicationRelauncher.restart()
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var windows: [String: NSWindow] = [:] // UUID -> NSWindow
    var viewModels: [String: BoringViewModel] = [:] // UUID -> BoringViewModel
    var window: NSWindow?
    let vm: BoringViewModel = .init()
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    var quickShareService = QuickShareService.shared
    var whatsNewWindow: NSWindow?
    private var clipboardWindow: NSWindow?
    private var clipboardViewModel: BoringViewModel?
    private weak var activeClipboardWindow: NSWindow?
    private weak var activeClipboardViewModel: BoringViewModel?
    private weak var clipboardPrimaryWindowHiddenForLock: NSWindow?
    private var clipboardPreviouslyActiveApplication: NSRunningApplication?
    private var clipboardShortcutAction: (() -> Void)?
    private var clipboardWindowResignObserver: Any?
    private var clipboardGlobalMouseMonitor: Any?
    private var clipboardLocalMouseMonitor: Any?
    private var clipboardFocusWorkItem: DispatchWorkItem?
    var timer: Timer?
    var closeNotchTask: Task<Void, Never>?
    private var previousScreens: [NSScreen]?
    private var onboardingWindowController: NSWindowController?
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
    private var isScreenLocked: Bool = false
    private var windowScreenDidChangeObserver: Any?
    private var dragDetectors: [String: DragDetector] = [:] // UUID -> DragDetector

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MusicManager.shared.destroy()
        clipboardFocusWorkItem?.cancel()
        removeClipboardOutsideClickMonitors()
        if let clipboardWindowResignObserver {
            NotificationCenter.default.removeObserver(clipboardWindowResignObserver)
            self.clipboardWindowResignObserver = nil
        }
        ClipboardHistoryViewModel.shared.stopMonitoring()
        ClipboardHotKey.shared.unregister()
        cleanupDragDetectors()
        cleanupWindows()
        if let clipboardWindow {
            clipboardWindow.close()
            NotchSpaceManager.shared.notchSpace.windows.remove(clipboardWindow)
        }
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()
    }

    @MainActor
    func onScreenLocked(_ notification: Notification) {
        isScreenLocked = true
        if let activeClipboardWindow, activeClipboardWindow !== clipboardWindow {
            clipboardPrimaryWindowHiddenForLock = activeClipboardWindow
        }
        closeClipboardPanel(restorePreviousApplication: false, hideWindow: true)
        clipboardWindow?.orderOut(nil)
        if Defaults[.clipboardPauseOnLockScreen] {
            ClipboardHistoryViewModel.shared.stopMonitoring()
        }
        if !Defaults[.showOnLockScreen] {
            cleanupWindows()
        } else {
            enableSkyLightOnAllWindows()
        }
    }

    @MainActor
    func onScreenUnlocked(_ notification: Notification) {
        isScreenLocked = false
        if let clipboardPrimaryWindowHiddenForLock {
            clipboardPrimaryWindowHiddenForLock.orderFrontRegardless()
            self.clipboardPrimaryWindowHiddenForLock = nil
        }
        ClipboardHistoryViewModel.shared.applyPreferences()
        if !Defaults[.showOnLockScreen] {
            adjustWindowPosition(changeAlpha: true)
        } else {
            disableSkyLightOnAllWindows()
        }
    }
    
    @MainActor
    private func enableSkyLightOnAllWindows() {
        if Defaults[.showOnAllDisplays] {
            windows.values.forEach { window in
                if let skyWindow = window as? BoringNotchSkyLightWindow {
                    skyWindow.enableSkyLight()
                }
            }
        } else {
            if let skyWindow = window as? BoringNotchSkyLightWindow {
                skyWindow.enableSkyLight()
            }
        }
    }
    
    @MainActor
    private func disableSkyLightOnAllWindows() {
        // Delay disabling SkyLight to avoid flicker during unlock transition
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await MainActor.run {
                if Defaults[.showOnAllDisplays] {
                    self.windows.values.forEach { window in
                        if let skyWindow = window as? BoringNotchSkyLightWindow {
                            skyWindow.disableSkyLight()
                        }
                    }
                } else {
                    if let skyWindow = self.window as? BoringNotchSkyLightWindow {
                        skyWindow.disableSkyLight()
                    }
                }
            }
        }
    }

    private func cleanupWindows(shouldInvert: Bool = false) {
        let shouldCleanupMulti = shouldInvert ? !Defaults[.showOnAllDisplays] : Defaults[.showOnAllDisplays]
        
        if shouldCleanupMulti {
            windows.values.forEach { window in
                window.close()
                NotchSpaceManager.shared.notchSpace.windows.remove(window)
            }
            windows.removeAll()
            viewModels.removeAll()
        } else if let window = window {
            window.close()
            NotchSpaceManager.shared.notchSpace.windows.remove(window)
            if let obs = windowScreenDidChangeObserver {
                NotificationCenter.default.removeObserver(obs)
                windowScreenDidChangeObserver = nil
            }
            self.window = nil
        }
    }

    private func cleanupDragDetectors() {
        dragDetectors.values.forEach { detector in
            detector.stopMonitoring()
        }
        dragDetectors.removeAll()
    }

    private func setupDragDetectors() {
        cleanupDragDetectors()

        guard Defaults[.expandedDragDetection] else { return }

        if Defaults[.showOnAllDisplays] {
            for screen in NSScreen.screens {
                setupDragDetectorForScreen(screen)
            }
        } else {
            let preferredScreen: NSScreen? = window?.screen
                ?? NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
                ?? NSScreen.main

            if let screen = preferredScreen {
                setupDragDetectorForScreen(screen)
            }
        }
    }

    private func setupDragDetectorForScreen(_ screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        
        let screenFrame = screen.frame
        let notchHeight = openNotchSize.height
        let notchWidth = openNotchSize.width
        
        // Create notch region at the top-center of the screen where an open notch would occupy
        let notchRegion = CGRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        
        let detector = DragDetector(notchRegion: notchRegion)
        
        detector.onDragEntersNotchRegion = { [weak self] in
            Task { @MainActor in
                self?.handleDragEntersNotchRegion(onScreen: screen)
            }
        }
        
        dragDetectors[uuid] = detector
        detector.startMonitoring()
    }

    private func handleDragEntersNotchRegion(onScreen screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        
        if Defaults[.showOnAllDisplays], let viewModel = viewModels[uuid] {
            viewModel.currentView = .shelf
            viewModel.open()
        } else if !Defaults[.showOnAllDisplays], let windowScreen = window?.screen, screen == windowScreen {
            vm.currentView = .shelf
            vm.open()
        }
    }

    private func createBoringNotchWindow(for screen: NSScreen, with viewModel: BoringViewModel) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
        
        let window = BoringNotchSkyLightWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
        
        // Enable SkyLight only when screen is locked
        if isScreenLocked {
            window.enableSkyLight()
        } else {
            window.disableSkyLight()
        }

        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(viewModel)
        )

        window.orderFrontRegardless()
        NotchSpaceManager.shared.notchSpace.windows.insert(window)

        // Observe when the window's screen changes so we can update drag detectors
        windowScreenDidChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setupDragDetectors()
                }
        }
        return window
    }

    @MainActor
    private func openClipboardPanel(requestedViewModel: BoringViewModel? = nil) {
        guard let builtInScreen = NSScreen.screens.first(where: \.isBuiltInDisplay) else { return }
        logClipboardDiagnostics("open-start", targetScreen: builtInScreen)

        let viewModel: BoringViewModel
        let targetWindow: NSWindow
        if let requestedViewModel {
            guard requestedViewModel.screenUUID == builtInScreen.displayUUID else { return }
            if requestedViewModel === clipboardViewModel,
               let clipboardWindow {
                viewModel = requestedViewModel
                targetWindow = clipboardWindow
            } else if requestedViewModel === vm,
                      let window {
                viewModel = requestedViewModel
                targetWindow = window
            } else if let entry = viewModels.first(where: { $0.value === requestedViewModel }),
                      let window = windows[entry.key] {
                viewModel = requestedViewModel
                targetWindow = window
            } else {
                return
            }
        } else if Defaults[.showOnAllDisplays],
                  let uuid = builtInScreen.displayUUID,
                  let builtInViewModel = viewModels[uuid],
                  let builtInWindow = windows[uuid] {
            viewModel = builtInViewModel
            targetWindow = builtInWindow
        } else if let mainWindow = window,
                  mainWindow.screen?.isBuiltInDisplay == true {
            viewModel = vm
            targetWindow = mainWindow
        } else {
            if clipboardWindow == nil || clipboardViewModel == nil {
                guard let uuid = builtInScreen.displayUUID else { return }
                let dedicatedViewModel = BoringViewModel(screenUUID: uuid)
                let dedicatedWindow = createBoringNotchWindow(
                    for: builtInScreen,
                    with: dedicatedViewModel
                )
                clipboardWindow = dedicatedWindow
                clipboardViewModel = dedicatedViewModel
            }
            guard let clipboardWindow, let clipboardViewModel else { return }
            positionWindow(clipboardWindow, on: builtInScreen)
            viewModel = clipboardViewModel
            targetWindow = clipboardWindow
        }

        closeNotchTask?.cancel()
        closeNotchTask = nil
        viewModel.currentView = .clipboard
        viewModel.open(size: clipboardOpenNotchSize)

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        if frontmostApplication?.bundleIdentifier != ownBundleIdentifier {
            clipboardPreviouslyActiveApplication = frontmostApplication
        }
        activeClipboardWindow = targetWindow
        activeClipboardViewModel = viewModel
        if let observer = clipboardWindowResignObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        clipboardWindowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: targetWindow,
            queue: .main
        ) { [weak self, weak targetWindow] _ in
            Task { @MainActor in
                guard let self,
                      let targetWindow,
                      self.activeClipboardWindow === targetWindow else { return }
                self.closeClipboardPanel(restorePreviousApplication: true)
            }
        }
        installClipboardOutsideClickMonitors(for: targetWindow)
        if let keyboardWindow = targetWindow as? BoringNotchSkyLightWindow {
            keyboardWindow.acceptsKeyboardInput = true
        }
        viewModel.clipboardOwnsKeyboardFocus = true
        NSApp.activate(ignoringOtherApps: true)
        targetWindow.makeKeyAndOrderFront(nil)
        targetWindow.orderFrontRegardless()

        clipboardFocusWorkItem?.cancel()
        let focusWorkItem = DispatchWorkItem { [weak self, weak targetWindow, weak viewModel] in
            guard let self,
                  let targetWindow,
                  let viewModel,
                  self.activeClipboardWindow === targetWindow else { return }
            targetWindow.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .clipboardPanelDidOpen, object: viewModel)
            DispatchQueue.main.async {
                guard self.activeClipboardWindow === targetWindow else { return }
                self.logClipboardDiagnostics(
                    "keyboard-focused",
                    targetScreen: builtInScreen,
                    targetWindow: targetWindow,
                    viewModel: viewModel
                )
            }
        }
        clipboardFocusWorkItem = focusWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: focusWorkItem)
        logClipboardDiagnostics(
            "open-complete",
            targetScreen: builtInScreen,
            targetWindow: targetWindow,
            viewModel: viewModel
        )
    }

    @MainActor
    private func logClipboardDiagnostics(_ phase: String, targetScreen: NSScreen? = nil, targetWindow: NSWindow? = nil, viewModel: BoringViewModel? = nil) {
        let screenLines = NSScreen.screens.map { screen in
            let uuid = screen.displayUUID ?? "nil"
            return "screen=\(screen.localizedName) uuid=\(uuid) builtIn=\(screen.isBuiltInDisplay) frame=\(screen.frame)"
        }.joined(separator: " | ")
        let windowScreen = targetWindow?.screen
        let windowScreenName = windowScreen?.localizedName ?? "nil"
        let targetScreenName = targetScreen?.localizedName ?? "nil"
        let responderName = targetWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let windowLine = "windowFrame=\(String(describing: targetWindow?.frame)) windowVisible=\(targetWindow?.isVisible ?? false) windowKey=\(targetWindow?.isKeyWindow ?? false) firstResponder=\(responderName) windowScreen=\(windowScreenName) windowBuiltIn=\(windowScreen?.isBuiltInDisplay ?? false)"
        let targetLine = "targetScreen=\(targetScreenName) targetBuiltIn=\(targetScreen?.isBuiltInDisplay ?? false) notchState=\(String(describing: viewModel?.notchState))"
        NSLog("[ClipboardDiagnostics] \(phase) | \(screenLines) | \(targetLine) | \(windowLine)")
    }

    @MainActor
    private func positionWindow(_ window: NSWindow, on screen: NSScreen, changeAlpha: Bool = false) {
        if changeAlpha {
            window.alphaValue = 0
        }

        let screenFrame = screen.frame
        window.setFrameOrigin(
            NSPoint(
                x: screenFrame.origin.x + (screenFrame.width / 2) - window.frame.width / 2,
                y: screenFrame.origin.y + screenFrame.height - window.frame.height
            ))
        window.alphaValue = 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipboardPanelOpenRequested),
            name: .clipboardPanelOpenRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipboardPanelSwitchRequested),
            name: .clipboardPanelSwitchRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipboardPanelDidFinish),
            name: .clipboardSelectionCompleted,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipboardPanelDidRequestClose),
            name: .clipboardPanelShouldClose,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(notchContentHeightDidChange),
            name: .notchContentHeightChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition(changeAlpha: true)
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.automaticallySwitchDisplayChanged, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            Task { @MainActor in
                window.alphaValue = self.coordinator.selectedScreenUUID == self.coordinator.preferredScreenUUID ? 1 : 0
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.showOnAllDisplaysChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.cleanupWindows(shouldInvert: true)
                self.adjustWindowPosition(changeAlpha: true)
                self.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.expandedDragDetectionChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupDragDetectors()
            }
        }

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            if Defaults[.sneakPeekStyles] == .inline {
                let newStatus = !self.coordinator.expandingView.show
                self.coordinator.toggleExpandingView(status: newStatus, type: .music)
            } else {
                self.coordinator.toggleSneakPeek(
                    status: !self.coordinator.sneakPeek.show,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        ClipboardHistoryViewModel.shared.startMonitoring()

        clipboardShortcutAction = { [weak self] in
            self?.openClipboardPanel()
        }
        do {
            if let clipboardShortcutAction {
                try ClipboardHotKey.shared.register(action: clipboardShortcutAction)
            }
        } catch {
            ClipboardHistoryViewModel.shared.errorMessage = error.localizedDescription
            NSLog("[ClipboardHotKey] registration failed: %@", error.localizedDescription)
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { [weak self] in
                guard let self = self else { return }

                let mouseLocation = NSEvent.mouseLocation

                var viewModel = self.vm

                if Defaults[.showOnAllDisplays] {
                    for screen in NSScreen.screens {
                        if screen.frame.contains(mouseLocation) {
                            if let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                                viewModel = screenViewModel
                                break
                            }
                        }
                    }
                }

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                switch viewModel.notchState {
                case .closed:
                    await MainActor.run {
                        viewModel.open()
                    }

                    let task = Task { [weak viewModel] in
                        do {
                            try await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                viewModel?.close()
                            }
                        } catch { }
                    }
                    self.closeNotchTask = task
                case .open:
                    await MainActor.run {
                        viewModel.close()
                    }
                }
            }
        }

        if !Defaults[.showOnAllDisplays] {
            let viewModel = self.vm
            let window = createBoringNotchWindow(
                for: NSScreen.main ?? NSScreen.screens.first!, with: viewModel)
            self.window = window
            adjustWindowPosition(changeAlpha: true)
        } else {
            adjustWindowPosition(changeAlpha: true)
        }

        setupDragDetectors()

        if coordinator.firstLaunch {
            DispatchQueue.main.async {
                self.showOnboardingWindow()
            }
            playWelcomeSound()
        } else if MusicManager.shared.isNowPlayingDeprecated
            && Defaults[.mediaController] == .nowPlaying
        {
            DispatchQueue.main.async {
                self.showOnboardingWindow(step: .musicPermission)
            }
        }

        previousScreens = NSScreen.screens
    }

    func playWelcomeSound() {
        let audioPlayer = AudioPlayer()
        audioPlayer.play(fileName: "boring", fileExtension: "m4a")
    }

    func deviceHasNotch() -> Bool {
        if #available(macOS 12.0, *) {
            for screen in NSScreen.screens {
                if screen.safeAreaInsets.top > 0 {
                    return true
                }
            }
        }
        return false
    }

    @objc func screenConfigurationDidChange() {
        let currentScreens = NSScreen.screens

        let screensChanged =
            currentScreens.count != previousScreens?.count
            || Set(currentScreens.compactMap { $0.displayUUID })
                != Set(previousScreens?.compactMap { $0.displayUUID } ?? [])
            || Set(currentScreens.map { $0.frame }) != Set(previousScreens?.map { $0.frame } ?? [])

        previousScreens = currentScreens

        if screensChanged {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Display topology changes must tear down Clipboard before macOS can
                // migrate its high-level window onto a remaining external display.
                self.closeClipboardPanel(restorePreviousApplication: false, hideWindow: true)
                if let clipboardWindow = self.clipboardWindow {
                    clipboardWindow.orderOut(nil)
                    clipboardWindow.close()
                    NotchSpaceManager.shared.notchSpace.windows.remove(clipboardWindow)
                    self.clipboardWindow = nil
                    self.clipboardViewModel = nil
                }
                self.cleanupWindows()
                self.adjustWindowPosition()
                self.setupDragDetectors()
            }
        }
    }

    @objc func adjustWindowPosition(changeAlpha: Bool = false) {
        if Defaults[.showOnAllDisplays] {
            let currentScreenUUIDs = Set(NSScreen.screens.compactMap { $0.displayUUID })

            // Remove windows for screens that no longer exist
            for uuid in windows.keys where !currentScreenUUIDs.contains(uuid) {
                if let window = windows[uuid] {
                    window.close()
                    NotchSpaceManager.shared.notchSpace.windows.remove(window)
                    windows.removeValue(forKey: uuid)
                    viewModels.removeValue(forKey: uuid)
                }
            }

            // Create or update windows for all screens
            for screen in NSScreen.screens {
                guard let uuid = screen.displayUUID else { continue }
                
                if windows[uuid] == nil {
                    let viewModel = BoringViewModel(screenUUID: uuid)
                    let window = createBoringNotchWindow(for: screen, with: viewModel)

                    windows[uuid] = window
                    viewModels[uuid] = viewModel
                }

                if let window = windows[uuid], let viewModel = viewModels[uuid] {
                    positionWindow(window, on: screen, changeAlpha: changeAlpha)

                    if viewModel.notchState == .closed {
                        viewModel.close()
                    }
                }
            }
        } else {
            let selectedScreen: NSScreen

            if let preferredScreen = NSScreen.screen(withUUID: coordinator.preferredScreenUUID ?? "") {
                coordinator.selectedScreenUUID = coordinator.preferredScreenUUID ?? ""
                selectedScreen = preferredScreen
            } else if Defaults[.automaticallySwitchDisplay], let mainScreen = NSScreen.main,
                      let mainUUID = mainScreen.displayUUID {
                coordinator.selectedScreenUUID = mainUUID
                selectedScreen = mainScreen
            } else {
                if let window = window {
                    window.alphaValue = 0
                }
                return
            }

            vm.screenUUID = selectedScreen.displayUUID

            if window == nil {
                window = createBoringNotchWindow(for: selectedScreen, with: vm)
            }

            if let window = window {
                positionWindow(window, on: selectedScreen, changeAlpha: changeAlpha)

                if vm.notchState == .closed {
                    vm.close()
                } else {
                    vm.open(size: vm.currentView == .clipboard ? clipboardOpenNotchSize : openNotchSize)
                }
            }
        }
    }

    @MainActor
    @objc private func notchContentHeightDidChange(_ notification: Notification) {
        guard let viewModel = notification.object as? BoringViewModel,
              let height = notification.userInfo?["height"] as? CGFloat else { return }

        let targetWindow: NSWindow?
        if viewModel === clipboardViewModel {
            targetWindow = clipboardWindow
        } else if viewModel === vm {
            targetWindow = window
        } else {
            targetWindow = viewModels.first(where: { $0.value === viewModel })
                .flatMap { windows[$0.key] }
        }

        guard let targetWindow,
              let screen = viewModel.screenUUID.flatMap({ NSScreen.screen(withUUID: $0) }) ?? targetWindow.screen,
              height > 0,
              height <= screen.frame.height else { return }

        let frame = NSRect(
            x: screen.frame.midX - windowSize.width / 2,
            y: screen.frame.maxY - height,
            width: windowSize.width,
            height: height
        )
        guard !targetWindow.frame.equalTo(frame) else { return }
        targetWindow.setFrame(frame, display: true, animate: viewModel.notchState == .open)
        NSLog(
            "[NotchLayout] content-height=%.0f windowFrame=%@ screen=%@ clipboard=%@",
            height,
            NSStringFromRect(frame),
            screen.localizedName,
            viewModel.currentView == .clipboard ? "true" : "false"
        )
    }

    @MainActor
    private func installClipboardOutsideClickMonitors(for window: NSWindow) {
        removeClipboardOutsideClickMonitors()

        let closeIfOutside: () -> Void = { [weak self, weak window] in
            let point = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self,
                      let window,
                      self.activeClipboardWindow === window,
                      !window.frame.contains(point) else { return }
                self.closeClipboardPanel(restorePreviousApplication: true)
            }
        }

        clipboardGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { _ in
            closeIfOutside()
        }
        clipboardLocalMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            closeIfOutside()
            return event
        }
    }

    @MainActor
    private func removeClipboardOutsideClickMonitors() {
        if let clipboardGlobalMouseMonitor {
            NSEvent.removeMonitor(clipboardGlobalMouseMonitor)
            self.clipboardGlobalMouseMonitor = nil
        }
        if let clipboardLocalMouseMonitor {
            NSEvent.removeMonitor(clipboardLocalMouseMonitor)
            self.clipboardLocalMouseMonitor = nil
        }
    }

    @MainActor
    @objc private func clipboardPanelOpenRequested(_ notification: Notification) {
        guard let viewModel = notification.object as? BoringViewModel else { return }
        openClipboardPanel(requestedViewModel: viewModel)
    }

    @MainActor
    @objc private func clipboardPanelSwitchRequested(_ notification: Notification) {
        guard let viewModel = notification.object as? BoringViewModel,
              let targetView = notification.userInfo?["targetView"] as? NotchViews,
              activeClipboardViewModel === viewModel else { return }
        let targetWindow = activeClipboardWindow
        let usesDedicatedClipboardWindow = targetWindow === clipboardWindow
        closeClipboardPanel(
            restorePreviousApplication: usesDedicatedClipboardWindow,
            hideWindow: usesDedicatedClipboardWindow
        )
        guard !usesDedicatedClipboardWindow else { return }
        viewModel.currentView = targetView
        viewModel.open()
        targetWindow?.orderFrontRegardless()
    }

    @objc private func clipboardPanelDidFinish(_ notification: Notification) {
        closeClipboardPanel(restorePreviousApplication: true)
    }

    @objc private func clipboardPanelDidRequestClose(_ notification: Notification) {
        closeClipboardPanel(restorePreviousApplication: true)
    }

    private func closeClipboardPanel(
        restorePreviousApplication: Bool,
        hideWindow: Bool = false
    ) {
        guard activeClipboardWindow != nil || activeClipboardViewModel != nil else { return }
        clipboardFocusWorkItem?.cancel()
        clipboardFocusWorkItem = nil
        removeClipboardOutsideClickMonitors()
        if let observer = clipboardWindowResignObserver {
            NotificationCenter.default.removeObserver(observer)
            clipboardWindowResignObserver = nil
        }

        let window = activeClipboardWindow
        let viewModel = activeClipboardViewModel
        activeClipboardWindow = nil
        activeClipboardViewModel = nil

        viewModel?.close(force: true)
        viewModel?.currentView = .home
        viewModel?.clipboardOwnsKeyboardFocus = false
        if let keyboardWindow = window as? BoringNotchSkyLightWindow {
            keyboardWindow.acceptsKeyboardInput = false
        }
        if hideWindow {
            window?.orderOut(nil)
        }
        window?.resignKey()

        let previousApplication = clipboardPreviouslyActiveApplication
        clipboardPreviouslyActiveApplication = nil
        NSApp.deactivate()
        if restorePreviousApplication, let previousApplication, !previousApplication.isTerminated {
            previousApplication.activate(options: [.activateIgnoringOtherApps])
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    @objc func showMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(self)
    }

    private func showOnboardingWindow(step: OnboardingStep = .welcome) {
        if onboardingWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Onboarding"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    step: step,
                    onFinish: {
                        window.orderOut(nil)
//                        NSApp.setActivationPolicy(.accessory)
                        window.close()
                        NSApp.deactivate()
                    },
                    onOpenSettings: {
                        window.close()
                        SettingsWindowController.shared.showWindow()
                    }
                ))
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")

            onboardingWindowController = NSWindowController(window: window)
        }

//        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
    }
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let notchContentHeightChanged = Notification.Name("NotchContentHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")
}

extension CGRect: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin.x)
        hasher.combine(origin.y)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }

    public static func == (lhs: CGRect, rhs: CGRect) -> Bool {
        return lhs.origin == rhs.origin && lhs.size == rhs.size
    }
}
