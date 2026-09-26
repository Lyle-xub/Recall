import AppKit
import SwiftUI
import Combine

/// A dedicated native strip owns the input rectangle. Visual transparency is
/// independent of event handling, so it needs no captured-background placeholder.
@MainActor final class TimelinePanelController {
    static let height: CGFloat = 280
    private weak var parent: NSWindow?
    private let model: AppModel
    let panel: TimelineStripWindow
    private var subscriptions = Set<AnyCancellable>()
    private var presented = false
    private var transition = OverlayTransitionState()
    private let motion = TimelineStripMotion()
    /// The strip only emerges when the pointer approaches the bottom edge, so
    /// the resting archive scene stays clean like the reference design.
    private var hoverReveal = false { didSet { if oldValue != hoverReveal { sync() } } }
    private var mouseMonitor: Any?
    init(parent:NSWindow,model:AppModel) {
        self.parent = parent; self.model = model
        panel = TimelineStripWindow(contentRect:.zero,styleMask:[.borderless],backing:.buffered,defer:false)
        panel.title = "Recall Timeline"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.alphaValue = 1; panel.ignoresMouseEvents = false; panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = RecallWindowBehavior.collection
        panel.isReleasedWhenClosed = false; panel.isMovable = false
        panel.contentView = TransparentHostingView(rootView:AnimatedTimelineStrip(model:model,motion:motion))
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching:[.mouseMoved,.mouseEntered,.mouseExited]) { [weak self] event in
            guard let self,let parent = self.parent,parent.isVisible else { return event }
            // Hysteresis: once the strip is up, the pointer may roam its full
            // height without collapsing it mid-interaction.
            let threshold = parent.frame.minY+(self.panel.isVisible ? self.panel.frame.height+24:88)
            self.hoverReveal = NSEvent.mouseLocation.y <= threshold
            return event
        }
        Publishers.CombineLatest4(model.$searchPresented,model.$askOpen,model.$inspectorOpen,model.$settingsOpen)
            .map { $0 || $1 || $2 || $3 }.combineLatest(model.$usageOpen).map { $0 || $1 }.combineLatest(model.$onboardingOpen).map { $0 || $1 }.removeDuplicates().receive(on:RunLoop.main)
            .sink { [weak self] _ in self?.sync() }.store(in:&subscriptions)
        for notification in [NSWindow.didMoveNotification,NSWindow.didResizeNotification] {
            NotificationCenter.default.publisher(for:notification,object:parent).sink { [weak self] _ in self?.updateFrame() }.store(in:&subscriptions)
        }
        model.$settings.map(\.glassArchiveEnabled).removeDuplicates().receive(on:RunLoop.main).sink { [weak self] _ in self?.sync() }.store(in:&subscriptions)
        model.$timelineCursor.removeDuplicates().receive(on:RunLoop.main).sink { [weak self] _ in self?.sync() }.store(in:&subscriptions)
        NotificationCenter.default.publisher(for:NSApplication.didHideNotification).sink { [weak self] _ in self?.dismiss() }.store(in:&subscriptions)
    }
    deinit { if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) } }
    func present() { presented = true; sync() }
    func dismiss() {
        presented = false; model.timelineJumpOpen = false
        setVisible(false)
    }
    private func sync() {
        guard presented, let parent, parent.isVisible,
              !model.settings.glassArchiveEnabled || hoverReveal || model.timelineCursor != nil,
              !model.searchPresented, !model.askOpen, !model.inspectorOpen, !model.settingsOpen, !model.usageOpen, !model.onboardingOpen else {
            setVisible(false); return
        }
        updateFrame()
        setVisible(true)
    }
    private func setVisible(_ visible:Bool) {
        guard let token = transition.setVisible(visible) else { return }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if visible {
            model.timelineVisible = true
            if panel.parent == nil,let parent { parent.addChildWindow(panel,ordered:.above) }
            if !panel.isVisible { panel.alphaValue = 0; panel.orderFront(nil) }
        }
        withAnimation(reduced ? nil:.spring(response:visible ? 0.38:0.24,dampingFraction:0.9)) { motion.visible = visible }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduced ? 0:visible ? 0.24:0.18
            context.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
            panel.animator().alphaValue = visible ? 1:0
        },completionHandler:{ [weak self] in
            Task { @MainActor in
                guard let self,!visible,self.transition.isCurrent(token,visible:false) else { return }
                if let parent = self.panel.parent { parent.removeChildWindow(self.panel) }
                self.panel.orderOut(nil)
                self.model.timelineVisible = false
            }
        })
    }
    private func updateFrame() {
        guard let parent else { return }
        let height = model.settings.glassArchiveEnabled ? ArchiveViewportLayout.timelineHeight:Self.height
        let frame = NSRect(x:parent.frame.minX,y:parent.frame.minY,width:parent.frame.width,height:height)
        if panel.frame != frame { panel.setFrame(frame,display:true) }
    }
}

@MainActor private final class TimelineStripMotion: ObservableObject {
    @Published var visible = false
}

private struct AnimatedTimelineStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var motion: TimelineStripMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if model.settings.glassArchiveEnabled {
                ArchiveStripBackground(appearance:model.settings.appearance).allowsHitTesting(false)
            } else {
                DesktopBlur(fadesUpward:true).allowsHitTesting(false)
            }
            TimelineView(model:model,jumpOpen:Binding(get:{model.timelineJumpOpen},set:{model.timelineJumpOpen = $0}))
                .offset(y:motion.visible || reduceMotion ? 0:20)
        }.frame(height:model.settings.glassArchiveEnabled ? ArchiveViewportLayout.timelineHeight:TimelinePanelController.height)
        .preferredColorScheme(model.settings.glassArchiveEnabled ? ArchiveTone.colorScheme(model.settings.appearance):nil)
        .onExitCommand { model.dismissTimeline() }
    }
}

final class TimelineStripWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
