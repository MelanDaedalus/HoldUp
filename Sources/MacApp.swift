import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Combine
import SwiftUI

private enum CapturedSelection {
    case text(String)
    case inaccessible
    case protected
    case absent
}

private enum SelectionReader {
    static func read(from app: NSRunningApplication?) -> CapturedSelection {
        guard AXIsProcessTrusted() else { return .inaccessible }
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return .absent }
        let owner = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(owner, 0.15)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        guard let focused = node(owner, kAXFocusedUIElementAttribute) ?? node(system, kAXFocusedUIElementAttribute) else { return .absent }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success, pid == app.processIdentifier else { return .absent }

        var candidate: AXUIElement? = focused
        for _ in 0..<5 {
            guard let element = candidate else { break }
            AXUIElementSetMessagingTimeout(element, 0.15)
            if attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
                return .protected
            }
            if let text = attribute(element, kAXSelectedTextAttribute) as? String, !text.trimmed.isEmpty {
                return .text(text)
            }
            if let range = attribute(element, kAXSelectedTextRangeAttribute),
               CFGetTypeID(range) == AXValueGetTypeID() {
                let rangeValue = unsafeDowncast(range, to: AXValue.self)
                var selection = CFRange()
                if AXValueGetValue(rangeValue, .cfRange, &selection), selection.length > 0 {
                    guard selection.length <= PreparedCheck.excerptLimit * 4 else {
                        // Let the review panel ask for a shorter selection without fetching it.
                        return .absent
                    }
                    var result: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                                   range, &result) == .success,
                       let text = result as? String, !text.trimmed.isEmpty {
                        return .text(text)
                    }
                }
            }
            candidate = node(element, kAXParentAttribute)
        }
        return .absent
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private static func node(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}

@MainActor private final class CheckWindow: NSPanel {
    var onEscape: (() -> Void)?

    func keepVisibleDuringResearch(_ enabled: Bool) {
        collectionBehavior = enabled
            ? [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem!
    private var statusLabel: NSMenuItem!
    private var clipboardMenuItem: NSMenuItem!
    private var resumeMenuItem: NSMenuItem!
    private var settings: NSWindow?
    private var panel: CheckWindow?
    private var showingWelcome: Bool?
    private var previousApp: NSRunningApplication?
    private var hotkeys: [HotkeyAction: RegisteredHotkey] = [:]
    private var hotkeyHandler: EventHandlerRef?
    private var hotkeySerial: UInt32 = 0
    private nonisolated static let hotkeySignature: OSType = 0x434C4D43

    private enum HotkeyAction: String {
        case selection = "Check Selection"
        case clipboard = "Check Clipboard"
    }

    private struct RegisteredHotkey {
        let ref: EventHotKeyRef
        let id: UInt32
    }

    private var recorder: Any?
    private var permissionPoll: Task<Void, Never>?
    private var terminationStarted = false
    private var diagnosticSubscriptions: Set<AnyCancellable> = []
    private var lastDiagnosticIssue: BetaDiagnostics.Issue?

    private var actions: AppActions {
        AppActions(
            openModels: { [weak self] in self?.openModels() },
            accessibility: { [weak self] in self?.requestAccessibility() },
            openOllama: { [weak self] in self?.openOllama() },
            clipboard: { [weak self] in self?.checkClipboard() },
            pasteContext: { [weak self] in self?.pasteContext() },
            previewClipboard: { [weak self] in self?.previewClipboard() },
            sample: { [weak self] in self?.openSample() },
            recordShortcut: { [weak self] in self?.toggleRecording(.selection) },
            recordClipboardShortcut: { [weak self] in self?.toggleRecording(.clipboard) },
            toggleShortcut: { [weak self] in self?.toggleShortcut($0) },
            dismissPanel: { [weak self] in self?.dismissPanel() },
            finishWelcome: { [weak self] in self?.finishWelcome() },
            stopResearch: { [weak self] in self?.panel?.keepVisibleDuringResearch(false) }
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.canReadSelection = AXIsProcessTrusted()
        observeFailures()
        makeApplicationMenu()
        makeStatusMenu()
        installHotkeyHandler()
        if state.shortcutEnabled { registerConfiguredHotkeys() }
        if state.needsSetup { openMain(welcome: true) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        state.canReadSelection = AXIsProcessTrusted()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if state.excerpt.isEmpty && state.pastedText.isEmpty {
            openMain(welcome: state.needsSetup)
        } else {
            resumeReview()
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationStarted else { return .terminateLater }
        terminationStarted = true
        unregisterHotkeys()
        stopRecording()
        permissionPoll?.cancel()
        Task {
            await state.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settings { stopRecording() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel {
            dismissPanel()
            return false
        }
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        statusLabel.title = state.isReady ? "Local model · \(state.engineLabel)" : "Model setup needed"
        clipboardMenuItem.title = hotkeys[.clipboard] == nil ? "Check Clipboard" : "Check Clipboard  \(state.clipboardShortcut.label)"
        resumeMenuItem.isHidden = state.excerpt.isEmpty && state.pastedText.isEmpty
        state.canReadSelection = AXIsProcessTrusted()
    }

    private func makeStatusMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusLabel = menu.addItem(withTitle: "Model setup needed", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        resumeMenuItem = menu.addItem(withTitle: "Resume Current Review", action: #selector(resumeReview), keyEquivalent: "")
        resumeMenuItem.target = self
        resumeMenuItem.isHidden = true
        clipboardMenuItem = menu.addItem(withTitle: "Check Clipboard", action: #selector(checkClipboard), keyEquivalent: "")
        clipboardMenuItem.target = self
        add("Try a Sample", #selector(openSample), to: menu)
        add("Settings…", #selector(openSettings), key: ",", to: menu)
        menu.addItem(.separator())
        add("Report a Problem…", #selector(reportProblem), to: menu)
        add("Copy Diagnostics", #selector(copyDiagnostics), to: menu)
        menu.addItem(.separator())
        add("Quit Hold UP", #selector(quit), key: "q", to: menu)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: "Hold UP")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "Hold UP"
        statusItem.menu = menu
    }

    private func makeApplicationMenu() {
        let main = NSMenu()
        let application = NSMenu(title: "Hold UP")
        add("Quit Hold UP", #selector(quit), key: "q", to: application)
        let applicationItem = NSMenuItem()
        applicationItem.submenu = application
        main.addItem(applicationItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func add(_ title: String, _ action: Selector, key: String = "", to menu: NSMenu) {
        menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
    }

    @objc private func openSettings() {
        openMain(welcome: false)
    }

    private func openModels() {
        panel?.orderOut(nil)
        state.section = .models
        openMain(welcome: state.needsSetup)
    }

    private func observeFailures() {
        state.$modelError.sink { [weak self] message in
            guard let message else { return }
            self?.lastDiagnosticIssue = .init(area: .setup, message: message)
        }.store(in: &diagnosticSubscriptions)
        state.$checkStatus.sink { [weak self] status in
            guard case .failed(let message) = status else { return }
            self?.lastDiagnosticIssue = .init(area: .check, message: message)
        }.store(in: &diagnosticSubscriptions)
        state.$failedEvidenceCount.sink { [weak self] count in
            guard count > 0 else { return }
            self?.lastDiagnosticIssue = .init(area: .sources)
        }.store(in: &diagnosticSubscriptions)
        state.$webStatus.sink { [weak self] status in
            guard let issue = BetaDiagnostics.Issue.sourceIssue(for: status) else { return }
            self?.lastDiagnosticIssue = issue
        }.store(in: &diagnosticSubscriptions)
        state.$shortcutError.sink { [weak self] message in
            guard message != nil else { return }
            self?.lastDiagnosticIssue = .init(area: .shortcut)
        }.store(in: &diagnosticSubscriptions)
    }

    private var diagnostics: BetaDiagnostics {
        BetaDiagnostics(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                        osVersion: ProcessInfo.processInfo.operatingSystemVersion,
                        model: state.engine == .builtIn ? .builtIn(state.store.asset.name) : .ollama(state.ollamaModel),
                        issue: lastDiagnosticIssue)
    }

    @objc private func copyDiagnostics() {
        copyToClipboard(diagnostics.text)
    }

    @objc private func reportProblem() {
        guard NSApp.modalWindow == nil else { return }
        let frontApp = NSWorkspace.shared.frontmostApplication
        let report = diagnostics.report
        let alert = NSAlert()
        alert.messageText = "Report a Problem"
        alert.informativeText = "Preview and copy a report to share with the beta maintainer."
        alert.addButton(withTitle: "Copy Report")
        alert.addButton(withTitle: "Cancel")

        let frame = NSRect(x: 0, y: 0, width: 385, height: 170)
        let preview = NSTextView(frame: frame)
        preview.isEditable = false
        preview.isSelectable = true
        preview.isVerticallyResizable = true
        preview.string = report
        preview.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.textContainerInset = NSSize(width: 8, height: 8)
        preview.textContainer?.widthTracksTextView = true
        preview.autoresizingMask = [.width]
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = preview
        alert.accessoryView = scroll
        alert.window.level = .modalPanel
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { copyToClipboard(report) }
        if let frontApp, !frontApp.isTerminated, frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            frontApp.activate()
        }
    }

    private func copyToClipboard(_ text: String) {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
    }

    private func openMain(welcome: Bool) {
        let size = welcome ? NSSize(width: 610, height: 442) : NSSize(width: 706, height: 535)
        let window: NSWindow
        if let settings {
            window = settings
        } else {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 575, height: 435)
            window.appearance = NSAppearance(named: .darkAqua)
            window.delegate = self
            window.center()
            settings = window
        }
        if let showingWelcome, welcome != showingWelcome { window.setContentSize(size) }
        showingWelcome = welcome
        window.title = welcome ? "Hold UP" : "Hold UP Settings"
        if welcome {
            window.contentView = NSHostingView(rootView: SetupView(state: state, actions: actions))
        } else {
            window.contentView = NSHostingView(rootView: SettingsView(state: state, actions: actions))
        }
        state.canReadSelection = AXIsProcessTrusted()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func finishWelcome() {
        state.finishWelcome()
        if state.welcomeCompleted { settings?.close() }
    }

    private func requestAccessibility() {
        let settings = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        state.canReadSelection = AXIsProcessTrustedWithOptions(settings)
        permissionPoll?.cancel()
        guard !state.canReadSelection else { return }
        permissionPoll = Task { [weak self] in
            for _ in 0..<80 {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.state.canReadSelection = true
                    return
                }
            }
        }
    }

    private func openOllama() {
        guard let url = OllamaEngine.applicationURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    fileprivate func selectionShortcut() {
        guard !state.recordingShortcut else { return }
        let sourceApp = NSWorkspace.shared.frontmostApplication
        recordPrevious(sourceApp)
        let capture = SelectionReader.read(from: sourceApp)
        state.canReadSelection = AXIsProcessTrusted()
        switch capture {
        case .text(let text):
            state.present(text: text, source: "Selected in \(sourceApp?.localizedName ?? "another app")")
        case .inaccessible:
            state.present(text: nil, source: "", missing: "Copy the text and choose Check Clipboard. Enable Accessibility to check directly from a selection.")
        case .protected:
            state.present(text: nil, source: "", missing: "Select text outside the protected field or paste a passage here.")
        case .absent:
            state.present(text: nil, source: "", missing: "No readable selection. Highlight a passage, paste it here, or check the clipboard.")
        }
        showPanel()
    }

    @objc private func checkClipboard() {
        recordPrevious(NSWorkspace.shared.frontmostApplication)
        state.present(text: NSPasteboard.general.string(forType: .string), source: "From clipboard", missing: "Copy a passage or paste text to check.")
        showPanel()
    }

    private func previewClipboard() {
        state.pastedText = NSPasteboard.general.string(forType: .string) ?? ""
    }

    private func pasteContext() {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmed, !text.isEmpty else { return }
        state.context += state.context.trimmed.isEmpty ? text : "\n\n" + text
        state.contextExpanded = true
    }

    @objc private func openSample() {
        recordPrevious(NSWorkspace.shared.frontmostApplication)
        state.presentSample()
        showPanel()
    }

    @objc private func resumeReview() {
        guard !state.excerpt.isEmpty || !state.pastedText.isEmpty else { return }
        recordPrevious(NSWorkspace.shared.frontmostApplication)
        showPanel()
    }

    func openReviewLink(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == "https", state.evidenceClaim != nil {
            panel?.keepVisibleDuringResearch(true)
        }
        return .systemAction
    }

    private func recordPrevious(_ app: NSRunningApplication?) {
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = app
        }
    }

    private func showPanel() {
        let review: CheckWindow
        if let panel {
            review = panel
        } else {
            review = CheckWindow(contentRect: NSRect(x: 0, y: 0, width: 502, height: 405),
                                 styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            review.title = "Hold UP"
            review.titleVisibility = .hidden
            review.titlebarAppearsTransparent = true
            review.standardWindowButton(.closeButton)?.isHidden = true
            review.standardWindowButton(.miniaturizeButton)?.isHidden = true
            review.standardWindowButton(.zoomButton)?.isHidden = true
            review.isReleasedWhenClosed = false
            review.isFloatingPanel = true
            review.hidesOnDeactivate = false
            review.isMovableByWindowBackground = true
            review.level = .floating
            review.keepVisibleDuringResearch(false)
            review.contentMinSize = NSSize(width: 398, height: 270)
            review.appearance = NSAppearance(named: .darkAqua)
            review.delegate = self
            review.onEscape = { [weak self] in self?.dismissPanel() }
            let content = ReviewPanel(state: state, actions: actions)
                .environment(\.openURL, OpenURLAction { [weak self] in self?.openReviewLink($0) ?? .systemAction })
            review.contentView = NSHostingView(rootView: content)
            panel = review
        }
        if state.evidenceClaim == nil { review.keepVisibleDuringResearch(false) }
        if !review.isVisible, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            var frame = review.frame
            frame.size.width = min(frame.width, visible.width - 28)
            frame.size.height = min(frame.height, visible.height - 28)
            frame.origin = NSPoint(x: visible.maxX - frame.width - 14, y: visible.maxY - frame.height - 14)
            review.setFrame(frame, display: true)
        }
        review.makeKeyAndOrderFront(nil)
    }

    private func dismissPanel(restoreFocus: Bool = true) {
        let shouldRestore = restoreFocus && panel?.isKeyWindow == true
        panel?.orderOut(nil)
        panel?.keepVisibleDuringResearch(false)
        state.closePanel()
        if shouldRestore, let previousApp, !previousApp.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    private func installHotkeyHandler() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == AppDelegate.hotkeySignature, Thread.isMainThread else {
                return OSStatus(eventNotHandledErr)
            }
            let id = identifier.id
            return MainActor.assumeIsolated {
                (NSApp.delegate as? AppDelegate)?.handleHotkey(id) ?? OSStatus(eventNotHandledErr)
            }
        }, 1, &event, nil, &hotkeyHandler)
        if result != noErr { state.shortcutError = "The system couldn’t register a global shortcut." }
    }

    private func handleHotkey(_ id: UInt32) -> OSStatus {
        guard state.shortcutEnabled, !terminationStarted,
              let action = hotkeys.first(where: { $0.value.id == id })?.key else {
            return OSStatus(eventNotHandledErr)
        }
        if let recordingAction {
            // Carbon consumes the registered chord before a local monitor sees it.
            saveRecordedShortcut(shortcut(for: action), for: recordingAction)
        } else {
            Task { [weak self] in
                guard let self, self.state.shortcutEnabled, !self.state.recordingShortcut,
                      !self.terminationStarted, self.hotkeys[action]?.id == id else { return }
                switch action {
                case .selection: self.selectionShortcut()
                case .clipboard: self.checkClipboard()
                }
            }
        }
        return noErr
    }

    private func register(_ chord: Shortcut, for action: HotkeyAction) -> Bool {
        guard hotkeyHandler != nil else { return false }
        var ref: EventHotKeyRef?
        hotkeySerial &+= 1
        let id = EventHotKeyID(signature: Self.hotkeySignature, id: hotkeySerial)
        let options = action == .clipboard ? UInt32(kEventHotKeyExclusive) : 0
        guard RegisterEventHotKey(chord.keyCode, chord.modifiers, id, GetApplicationEventTarget(), options, &ref) == noErr,
              let ref else {
            state.shortcutError = "\(chord.label) is unavailable for \(action.rawValue). Choose another shortcut."
            return false
        }
        let replacement = RegisteredHotkey(ref: ref, id: id.id)
        if let previous = hotkeys.updateValue(replacement, forKey: action) {
            _ = UnregisterEventHotKey(previous.ref)
        }
        return true
    }

    private func unregisterHotkeys() {
        for hotkey in hotkeys.values { _ = UnregisterEventHotKey(hotkey.ref) }
        hotkeys.removeAll()
    }

    private func registerConfiguredHotkeys() {
        if hotkeys[.selection] == nil { _ = register(state.shortcut, for: .selection) }
        guard hotkeys[.clipboard] == nil else { return }
        guard !sameChord(state.shortcut, state.clipboardShortcut) else {
            state.shortcutError = "\(state.clipboardShortcut.label) is assigned to Check Selection. Choose a different clipboard shortcut."
            return
        }
        _ = register(state.clipboardShortcut, for: .clipboard)
    }

    private func toggleShortcut(_ enabled: Bool) {
        state.shortcutError = nil
        if enabled {
            registerConfiguredHotkeys()
            state.setShortcutEnabled(!hotkeys.isEmpty)
        } else {
            unregisterHotkeys()
            state.setShortcutEnabled(false)
        }
    }

    private var recordingAction: HotkeyAction? {
        guard state.recordingShortcut else { return nil }
        return state.recordingClipboardShortcut ? .clipboard : .selection
    }

    private func shortcut(for action: HotkeyAction) -> Shortcut {
        action == .clipboard ? state.clipboardShortcut : state.shortcut
    }

    private func sameChord(_ first: Shortcut, _ second: Shortcut) -> Bool {
        first.keyCode == second.keyCode && first.modifiers == second.modifiers
    }

    private func toggleRecording(_ action: HotkeyAction) {
        if recordingAction == action { stopRecording(); return }
        state.recordingShortcut = true
        state.recordingClipboardShortcut = action == .clipboard
        state.shortcutError = nil
        guard recorder == nil else { return }
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.record(event)
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        guard let recordingAction else { return }
        if event.keyCode == UInt16(kVK_Escape) { stopRecording(); return }
        let flags = event.modifierFlags
        guard !flags.intersection([.control, .option, .command]).isEmpty else {
            state.shortcutError = "Include Control, Option, or Command."
            return
        }
        let names: [UInt16: String] = [UInt16(kVK_Space): "Space", UInt16(kVK_Return): "Return",
                                       UInt16(kVK_Tab): "Tab", UInt16(kVK_Delete): "Delete"]
        let key = names[event.keyCode] ?? event.charactersIgnoringModifiers?.trimmed.uppercased() ?? ""
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            state.shortcutError = "Use a letter, number, or Space with a modifier."
            return
        }

        let available: [(NSEvent.ModifierFlags, Int, String)] = [
            (.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")
        ]
        let pressed = available.filter { flags.contains($0.0) }
        let chord = Shortcut(keyCode: UInt32(event.keyCode), modifiers: UInt32(pressed.reduce(0) { $0 | $1.1 }),
                             label: pressed.map(\.2).joined() + key)
        saveRecordedShortcut(chord, for: recordingAction)
    }

    private func saveRecordedShortcut(_ chord: Shortcut, for action: HotkeyAction) {
        let other: HotkeyAction = action == .clipboard ? .selection : .clipboard
        guard !sameChord(chord, shortcut(for: other)) else {
            state.shortcutError = "\(chord.label) is already assigned to \(other.rawValue). Choose another shortcut."
            return
        }
        let unchanged = hotkeys[action] != nil && sameChord(chord, shortcut(for: action))
        guard unchanged || register(chord, for: action) else { return }
        switch action {
        case .selection: state.updateShortcut(chord)
        case .clipboard: state.updateClipboardShortcut(chord)
        }
        stopRecording()
        registerConfiguredHotkeys()
    }

    private func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        state.recordingShortcut = false
        state.recordingClipboardShortcut = false
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

@main struct ClaimCheck {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
