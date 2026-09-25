import AppKit
import Carbon

/// Carbon hot keys work while Recall is hidden, without an accessibility event tap.
@MainActor final class GlobalShortcut {
    static let signature: OSType = 0x52434C4C
    private var handler: EventHandlerRef?
    private var registrations: [String:(ref:EventHotKeyRef,id:UInt32)] = [:]
    private var nextID:UInt32 = 1
    private var validIDs:Set<UInt32> = [1,2]
    private(set) var configuration = ShortcutConfiguration()
    private var suspended = false
    private var held = Set<UInt32>()
    var action: (() -> Void)?
    var diagnostic: ((String) -> Void)?

    func register(_ config:ShortcutConfiguration = ShortcutConfiguration()) -> (available:Bool, message:String) {
        do { return try configure(config,strict:false) }
        catch { return (false,error.localizedDescription) }
    }
    func configure(_ config:ShortcutConfiguration,strict:Bool = true) throws -> (available:Bool,message:String) {
        try config.validate()
        guard !suspended else { throw RewindError.message("Finish recording the shortcut before saving.") }
        try installHandler()
        let bindings = [config.open,config.alternate].compactMap { $0 }
        var pending = [String:(ref:EventHotKeyRef,id:UInt32)]()
        var failures = [String]()
        for binding in bindings where registrations[binding.identity] == nil {
            var ref:EventHotKeyRef?
            let id = nextID; nextID += 1
            let status = RegisterEventHotKey(binding.keyCode,binding.modifiers,EventHotKeyID(signature:Self.signature,id:id),GetEventDispatcherTarget(),0,&ref)
            if status == noErr,let ref { pending[binding.identity] = (ref,id) }
            else { failures.append("\(binding.label) is unavailable (\(status))") }
        }
        if strict,!failures.isEmpty {
            pending.values.forEach { UnregisterEventHotKey($0.ref) }
            throw RewindError.message(failures.joined(separator:". ") + ". Your previous shortcuts are unchanged.")
        }
        let wanted = Set(bindings.map(\.identity))
        for (identity,item) in registrations where !wanted.contains(identity) { UnregisterEventHotKey(item.ref) }
        registrations = registrations.filter { wanted.contains($0.key) }.merging(pending) { old,_ in old }
        validIDs = Set(registrations.values.map(\.id)); held = []; configuration = config
        let ready = bindings.filter { registrations[$0.identity] != nil }.map(\.label)
        diagnostic?("Shortcut registration: ready=\(ready.joined(separator:"; ")); failures=\(failures.count)")
        let message = (ready.isEmpty ? "":ready.joined(separator:" and ") + " ready. ") + failures.joined(separator:". ")
        return (!ready.isEmpty,message)
    }
    func setSuspended(_ value:Bool) {
        guard value != suspended else { return }
        if value { unregister(); suspended = true }
        else { suspended = false; _ = register(configuration) }
    }
    private func installHandler() throws {
        guard handler == nil else { return }
        var events = [
            EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyReleased))
        ]
        let target = GetEventDispatcherTarget()
        let handlerStatus = InstallEventHandler(target,{ _,event,data in
            guard let event,let data else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let status = GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&key)
            guard status == noErr,key.signature == GlobalShortcut.signature else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(data).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { shortcut.receive(id:key.id,pressed:pressed) }
            return noErr
        },events.count,&events,Unmanaged.passUnretained(self).toOpaque(),&handler)
        guard handlerStatus == noErr else { throw RewindError.message("Global shortcut unavailable (\(handlerStatus)). Retry registration below.") }
    }
    func receive(id:UInt32,pressed:Bool) {
        guard validIDs.contains(id) else { return }
        if pressed {
            guard held.insert(id).inserted else { return }
            diagnostic?("Shortcut pressed: \(id)")
            // Resolve visibility synchronously once; queueing a Task per key repeat
            // can otherwise show and immediately hide the same window.
            action?()
        } else { held.remove(id) }
    }
    func unregister() {
        registrations.values.forEach { UnregisterEventHotKey($0.ref) }; registrations = [:]
        if let handler { RemoveEventHandler(handler) }; handler = nil
        held = []
    }
}

extension Notification.Name {
    static let recallShortcutCapture = Notification.Name("RecallShortcutCapture")
    static let recallSettingsSaved = Notification.Name("RecallSettingsSaved")
    static let recallGoBack = Notification.Name("RecallGoBack")
    static let recallRetryShortcut = Notification.Name("RecallRetryShortcut")
}
