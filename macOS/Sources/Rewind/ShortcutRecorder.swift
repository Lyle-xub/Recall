import SwiftUI
import AppKit

struct ShortcutRecorder: NSViewRepresentable {
    let title: String
    @Binding var binding: ShortcutBinding?
    let global: Bool
    var changed: ()->Void = {}
    func makeNSView(context:Context)->ShortcutRecorderView { let view = ShortcutRecorderView(); configure(view); return view }
    func updateNSView(_ view:ShortcutRecorderView,context:Context) { configure(view) }
    private func configure(_ view:ShortcutRecorderView) {
        view.actionTitle = title; view.binding = binding; view.global = global
        view.onChange = { binding = $0; changed() }
        view.refresh()
    }
    static func dismantleNSView(_ view:ShortcutRecorderView,coordinator:()) { view.finish() }
}

final class ShortcutRecorderView: NSButton {
    var actionTitle = ""
    var binding: ShortcutBinding?
    var global = true
    var onChange: ((ShortcutBinding)->Void)?
    private(set) var recordingKey = false
    private var originalTitle = ""
    override init(frame:NSRect) {
        super.init(frame:frame)
        bezelStyle = .rounded; controlSize = .large
        target = self; action = #selector(begin)
        font = .monospacedSystemFont(ofSize:12,weight:.medium)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?)->Bool { true }
    func refresh() {
        guard !recordingKey else { return }
        originalTitle = actionTitle
        setAccessibilityLabel("Record shortcut for \(originalTitle)")
        title = binding?.label ?? "Click to record"
        toolTip = "Click, then press a key combination. Escape cancels."
    }
    @objc private func begin() {
        guard !recordingKey else { return }
        recordingKey = true
        NotificationCenter.default.post(name:.recallShortcutCapture,object:true)
        window?.makeFirstResponder(self)
        title = "Press shortcut…"; needsDisplay = true
    }
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        guard recordingKey,event.type == .keyDown else { return super.performKeyEquivalent(with:event) }
        capture(event); return true
    }
    override func keyDown(with event:NSEvent) {
        if recordingKey { capture(event) } else { super.keyDown(with:event) }
    }
    func capture(_ event:NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53,event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty { finish(); return }
        let value = ShortcutBinding.from(event)
        do {
            try value.validate(global:global)
            binding = value; onChange?(value); finish()
        } catch { title = "Use ⌘, ⌃ or ⌥"; toolTip = error.localizedDescription; NSSound.beep() }
    }
    func finish() {
        guard recordingKey else { return }
        recordingKey = false
        NotificationCenter.default.post(name:.recallShortcutCapture,object:false)
        title = originalTitle; refresh()
    }
    override func resignFirstResponder()->Bool { finish(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow:NSWindow?) { if newWindow == nil { finish() }; super.viewWillMove(toWindow:newWindow) }
}
