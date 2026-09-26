import SwiftUI
import AppKit
import Carbon
import Combine

@main struct RewindApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {app.run()}
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var recordingDot:RecallRecordingDot?
    private let shortcut = GlobalShortcut()
    private var terminating = false
    private var responseWatchdog:UIResponseWatchdog?
    private var recordingItem: NSMenuItem?
    private var preferencesItem: NSMenuItem?
    private var findItem: NSMenuItem?
    private var showItem: NSMenuItem?
    private var recordingObserver: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let dataRoot: URL? = args.firstIndex(of:"--data-dir").flatMap {args.indices.contains($0+1) ? URL(fileURLWithPath:args[$0+1]):nil}
        if dataRoot == nil, let identifier = Bundle.main.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier:identifier).first(where:{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}) {
            running.activate(options:[.activateAllWindows])
            if let url = running.bundleURL { NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration()) }
            NSApp.terminate(nil); return
        }
        do {model = try AppModel(root:dataRoot)} catch {let alert = NSAlert();alert.messageText = "Recall could not open your library";alert.informativeText = error.localizedDescription;alert.runModal();NSApp.terminate(nil);return}
        responseWatchdog = UIResponseWatchdog(root:model.store.root)
        NSApp.setActivationPolicy(model.settings.showDockIcon ? .regular:.accessory)
        window = RewindOverlayWindow(contentRect:NSScreen.main?.frame ?? NSRect(x:0,y:0,width:1240,height:820),styleMask:[.borderless,.fullSizeContentView],backing:.buffered,defer:false)
        window.title = "Recall";window.titleVisibility = .hidden;window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true;window.standardWindowButton(.miniaturizeButton)?.isHidden = true;window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isOpaque = false;window.backgroundColor = .clear;window.hasShadow = false;window.level = .statusBar
        window.ignoresMouseEvents = false; window.acceptsMouseMovedEvents = true
        window.collectionBehavior = RecallWindowBehavior.collection
        (window as? NSPanel)?.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false;window.isReleasedWhenClosed = false;window.delegate = self
        window.contentView = TransparentHostingView(rootView:RootView(model:model));model.window = window
        (window as? RewindOverlayWindow)?.visibilityChanged = { [weak self] visible in self?.model.interfaceVisibilityChanged(visible) }
        (window as? RewindOverlayWindow)?.timelineController = TimelinePanelController(parent:window,model:model)
        positionOverlay()
        NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.positionOverlay() } }
        setupMenu();setupShortcut(); updatePreferenceUI()
        model.configureShortcuts = { [weak self] config in
            guard let self else { return }
            let result = try self.shortcut.configure(config)
            self.model.shortcutAvailable = result.available; self.model.shortcutStatus = result.message
        }
        NotificationCenter.default.addObserver(forName:.recallSettingsSaved,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePreferenceUI() }
        }
        NotificationCenter.default.addObserver(forName:.recallShortcutCapture,object:nil,queue:.main) { [weak self] note in
            MainActor.assumeIsolated { self?.shortcut.setSuspended(note.object as? Bool ?? false) }
        }
        NotificationCenter.default.addObserver(forName:.recallRetryShortcut,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setupShortcut() }
        }
        show()
        NSEvent.addLocalMonitorForEvents(matching:[.keyDown]) { [weak self] event in
            guard let self else { return event }
            if let recorder = event.window?.firstResponder as? ShortcutRecorderView,recorder.recordingKey {
                recorder.capture(event); return nil
            }
            guard self.window.isVisible,!self.model.settingsOpen,!self.model.usageOpen,!self.model.onboardingOpen,event.window === self.window || event.window is TimelineStripWindow else { return event }
            let keys = self.model.settings.shortcuts
            let editing = event.window?.firstResponder is NSTextView || event.window?.firstResponder is IndexedTextOverlay
            if keys.search.matches(event) { self.focusSearch(); return nil }
            if keys.settings.matches(event) { self.settingsAction(); return nil }
            if keys.back.matches(event) { NotificationCenter.default.post(name:.recallGoBack,object:nil); return nil }
            if !editing {
                if keys.previous.matches(event) { self.model.step(-1); return nil }
                if keys.next.matches(event) { self.model.step(1); return nil }
            }
            return event
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
    // Resigning active also happens while AppKit hands focus to child panels,
    // popovers and sheets. It must not be treated as a request to close Recall.
    func applicationDidHide(_ notification:Notification) {
        if window?.isVisible == true { window.orderOut(nil) }
    }
    func applicationDidBecomeActive(_ notification:Notification) {
        Task { @MainActor in
            await Task.yield()
            guard self.window?.isVisible == true else { return }
            CaptureDiagnostics(root:self.model.store.root).write("Overlay active; dockHidden=\(NSApp.currentSystemPresentationOptions.contains(.hideDock)); currentSpace=\(self.window.isOnActiveSpace)")
        }
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {show();return true}
    func windowShouldClose(_ sender:NSWindow)->Bool {model.hideOverlay();return false}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if terminating || model == nil {return .terminateNow}
        terminating = true
        model.prepareToQuit()
        shortcut.unregister()
        window?.orderOut(nil)
        Task {await model.shutDownRecording();await model.storageOptimizer.stop();await LocalInference.shared.stop();NSApp.reply(toApplicationShouldTerminate:true)}
        return .terminateLater
    }
    private func setupMenu() {
        let menu = NSMenu();let appMenu = NSMenu();let root = NSMenuItem();root.submenu = appMenu;menu.addItem(root)
        let preferences = NSMenuItem(title:"Settings…",action:#selector(settingsAction),keyEquivalent:",");preferences.target = self;appMenu.addItem(preferences);preferencesItem = preferences
        let tour = NSMenuItem(title:"Welcome to Recall…",action:#selector(onboardingAction),keyEquivalent:"");tour.target = self;appMenu.addItem(tour)
        appMenu.addItem(.separator());appMenu.addItem(NSMenuItem(title:"Quit Recall",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"))
        let edit = NSMenuItem(title:"Edit",action:nil,keyEquivalent:"");let editMenu = NSMenu(title:"Edit");edit.submenu = editMenu;menu.addItem(edit)
        for (title,action,key) in [("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Cut",#selector(NSText.cut(_:)),"x"),("Select All",#selector(NSText.selectAll(_:)),"a")] {editMenu.addItem(NSMenuItem(title:title,action:action,keyEquivalent:key))}
        let find = NSMenuItem(title:"Search",action:#selector(focusSearch),keyEquivalent:"f");find.target = self;editMenu.addItem(find);findItem = find
        NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength:28)
        statusItem.autosaveName = "RecallStatusItem"
        statusItem.isVisible = true
        let icon = (NSImage(named:"RecallTemplate")?.copy() as? NSImage) ?? NSImage(systemSymbolName:"circle",accessibilityDescription:"Recall")
        icon?.isTemplate = true; icon?.size = NSSize(width:18,height:18)
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.setAccessibilityLabel("Recall")
        if let button = statusItem.button {
            let dot = RecallRecordingDot(frame:NSRect(x:button.bounds.width-7,y:3,width:4,height:4))
            dot.wantsLayer = true;dot.layer?.backgroundColor = NSColor.systemRed.cgColor;dot.layer?.cornerRadius = 2
            dot.autoresizingMask = [.minXMargin,.maxYMargin];dot.isHidden = true
            button.addSubview(dot);recordingDot = dot
        }
        let tray = NSMenu();let showItem = NSMenuItem(title:"Open Recall     ⌘⇧Space",action:#selector(show),keyEquivalent:"");showItem.target = self;tray.addItem(showItem);self.showItem = showItem
        let record = NSMenuItem(title:"Start / pause recording",action:#selector(toggleCapture),keyEquivalent:"");record.target = self;tray.addItem(record)
        recordingItem = record
        let usage = NSMenuItem(title:"App usage…",action:#selector(usageAction),keyEquivalent:"");usage.target = self;tray.addItem(usage)
        tray.addItem(.separator());let settings = NSMenuItem(title:"Settings…",action:#selector(settingsAction),keyEquivalent:"");settings.target = self;tray.addItem(settings)
        let welcome = NSMenuItem(title:"Welcome to Recall…",action:#selector(onboardingAction),keyEquivalent:"");welcome.target = self;tray.addItem(welcome)
        let quit = NSMenuItem(title:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"");tray.addItem(quit);statusItem.menu = tray
        showItem.image = icon
        for (item,symbol) in [(record,"record.circle"),(usage,"chart.bar.xaxis"),(settings,"slider.horizontal.3"),(welcome,"play.circle"),(quit,"power")] {
            let image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)
            image?.isTemplate = true;image?.size = NSSize(width:16,height:16);item.image = image
        }
        recordingObserver = Publishers.CombineLatest3(model.$recording,model.$recordingRequested,model.$recordingAutomaticallyPaused).receive(on:RunLoop.main).sink { [weak self] active,requested,automatic in
            self?.recordingItem?.title = requested ? "Pause recording":"Start recording"
            self?.recordingDot?.isHidden = !active
            self?.recordingItem?.image = NSImage(systemSymbolName:requested ? "pause.circle":"record.circle",accessibilityDescription:nil)
            self?.statusItem.button?.toolTip = automatic ? "Recall · Paused while open; resumes on close":active ? "Recall · Recording on this Mac":"Recall · Recording paused"
        }
    }
    private func setupShortcut() {
        shortcut.action = { [weak self] in
            guard let self else { return }
            let visible = (self.window as? RewindOverlayWindow)?.isPresented == true
            if visible && (self.window as? RewindOverlayWindow)?.ownsKeyboardFocus == true { self.model.hideOverlay() } else { self.show() }
        }
        shortcut.diagnostic = { [weak self] message in
            guard let self else { return }; CaptureDiagnostics(root:self.model.store.root).write(message)
        }
        let result = shortcut.register(model.settings.shortcuts)
        model.shortcutAvailable = result.available; model.shortcutStatus = result.message
    }
    private func updatePreferenceUI() {
        let wasVisible = (window as? RewindOverlayWindow)?.isPresented == true
        let policy: NSApplication.ActivationPolicy = model.settings.showDockIcon ? .regular:.accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if wasVisible { window.makeKeyAndOrderFront(nil) }
        }
        CaptureDiagnostics(root:model.store.root).write("Dock icon visible: \(NSApp.activationPolicy() == .regular)")
        showItem?.title = "Open Recall     " + model.settings.shortcuts.open.label
        applyMenuKey(model.settings.shortcuts.search,to:findItem)
        applyMenuKey(model.settings.shortcuts.settings,to:preferencesItem)
    }
    private func applyMenuKey(_ key:ShortcutBinding,to item:NSMenuItem?) {
        item?.keyEquivalent = key.keyLabel.count == 1 ? key.keyLabel.lowercased():""
        var flags:NSEvent.ModifierFlags = []
        if key.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if key.modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if key.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if key.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        item?.keyEquivalentModifierMask = flags
    }
    private func positionOverlay() {
        guard let screen = NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) ?? NSScreen.main else {return}
        window.setFrame(screen.frame,display:true)
        // Cover Dock in the current Space. Keep only the menu bar safe inset.
        model.desktopInsets = EdgeInsets(top:max(0,screen.frame.maxY-screen.visibleFrame.maxY),leading:0,bottom:0,trailing:0)
    }
    @objc func show() {
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        positionOverlay()
        NSApp.unhideWithoutActivation()
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name:Notification.Name("RewindPrepareSearch"),object:nil)
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,self.window.isVisible else { return }
            let retainedForeground = foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier
            CaptureDiagnostics(root:self.model.store.root).write("Overlay shown; key=\(self.window.isKeyWindow); currentSpace=\(self.window.isOnActiveSpace); retainedForeground=\(retainedForeground)")
        }
    }
    @objc func onboardingAction() {model.showOnboarding();show()}
    @objc func usageAction() {model.onboardingOpen = false;show();model.usageOpen = true}
    @objc func settingsAction() {model.onboardingOpen = false;show();model.settingsOpen = true}
    @objc func toggleCapture() {model.toggleRecording()}
    @objc func focusSearch() {NotificationCenter.default.post(name:Notification.Name("RewindFocusSearch"),object:nil)}
}

private final class RecallRecordingDot:NSView {
    override func hitTest(_ point:NSPoint)->NSView? { nil }
}

final class RewindOverlayWindow: NSPanel {
    override var canBecomeKey: Bool {true}
    override var canBecomeMain: Bool {false}
    override init(contentRect:NSRect,styleMask:NSWindow.StyleMask,backing:NSWindow.BackingStoreType,defer flag:Bool) {
        // Set this at construction: changing the flag later does not reliably
        // update WindowServer's activation policy. Key focus still works.
        super.init(contentRect:contentRect,styleMask:styleMask.union(.nonactivatingPanel),backing:backing,defer:flag)
        isFloatingPanel = true; hidesOnDeactivate = false; becomesKeyOnlyIfNeeded = false
    }
    var ownsKeyboardFocus:Bool {
        guard isPresented,isOnActiveSpace else { return false }
        var focused = NSApp.keyWindow
        while let window = focused {
            if window === self { return true }
            focused = window.sheetParent ?? window.parent
        }
        return false
    }
    private var transition = OverlayTransitionState()
    var isPresented: Bool { transition.visible }
    var timelineController: TimelinePanelController?
    var visibilityChanged:((Bool)->Void)?
    private let presentation = OverlayDockPresentation()
    override func makeKeyAndOrderFront(_ sender: Any?) {
        let appearing = transition.setVisible(true) != nil
        if appearing { visibilityChanged?(true) }
        presentation.begin()
        if !isVisible { alphaValue = 0 }
        // Take keyboard focus without activating Recall and switching away
        // from the app whose full-screen Space the user is currently viewing.
        orderFrontRegardless()
        super.makeKeyAndOrderFront(sender)
        timelineController?.present()
        if appearing {NSAnimationContext.runAnimationGroup {context in context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0:0.22;animator().alphaValue = 1}}
    }
    override func orderOut(_ sender: Any?) {
        dismiss(sender,hideApplication:false)
    }
    func dismiss(_ sender:Any? = nil,hideApplication:Bool,completion:(()->Void)? = nil) {
        guard let token = transition.setVisible(false) else { return }
        timelineController?.dismiss()
        let finish = { [weak self] in
            guard let self,self.transition.isCurrent(token,visible:false) else { return }
            self.hideImmediately(sender); self.presentation.end(); completion?(); self.visibilityChanged?(false)
            if hideApplication { NSApp.hide(nil) }
        }
        guard isVisible,!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { finish(); return }
        NSAnimationContext.runAnimationGroup({context in
            context.duration = 0.2; context.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
            animator().alphaValue = 0
        },completionHandler:finish)
    }
    private func hideImmediately(_ sender: Any?) {super.orderOut(sender);alphaValue = 1}
}
