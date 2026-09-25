import AppKit
import Carbon

struct ShortcutBinding: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String
    static let modifierMask = UInt32(cmdKey | controlKey | optionKey | shiftKey)
    var normalized: Self { Self(keyCode:keyCode,modifiers:modifiers & Self.modifierMask,keyLabel:keyLabel) }
    var identity: String { "\(keyCode):\(modifiers & Self.modifierMask)" }
    var keys: [String] {
        var result: [String] = []
        if modifiers & UInt32(controlKey) != 0 { result.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { result.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { result.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { result.append("⌘") }
        return result + [keyLabel]
    }
    var label: String { keys.joined(separator:" ") }
    static func carbonFlags(_ flags:NSEvent.ModifierFlags)->UInt32 {
        var result:UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
    static func from(_ event:NSEvent)->Self {
        let names: [UInt16:String] = [49:"Space",53:"Esc",36:"Return",48:"Tab",51:"Delete",117:"⌦",123:"←",124:"→",125:"↓",126:"↑",115:"Home",119:"End",116:"Page Up",121:"Page Down",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12"]
        return Self(keyCode:UInt32(event.keyCode),modifiers:carbonFlags(event.modifierFlags),keyLabel:names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
    }
    func matches(_ event:NSEvent)->Bool { keyCode == event.keyCode && modifiers == Self.carbonFlags(event.modifierFlags) }
    func validate(global:Bool) throws {
        guard keyCode <= 127,!keyLabel.isEmpty,modifiers & ~Self.modifierMask == 0 else { throw RewindError.message("This key combination is not supported.") }
        let hasModifier = modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
        guard hasModifier || (!global && [53,123,124,125,126].contains(keyCode)) else { throw RewindError.message("Include Command, Control or Option in this shortcut.") }
        if modifiers == UInt32(cmdKey),[0,4,6,7,8,9,12,13,46,48,49,50].contains(keyCode) {
            throw RewindError.message("That combination is reserved for a standard macOS command. Choose another.")
        }
    }
}

enum RecallShortcutAction: String, CaseIterable, Identifiable {
    case open, alternate, search, previous, next, back, settings
    var id: String { rawValue }
    var title: String { switch self {
        case .open: "Open / hide Recall"; case .alternate: "Alternate shortcut"; case .search: "Search"; case .previous: "Previous moment"; case .next: "Next moment"; case .back: "Back / close"; case .settings: "Settings"
    } }
    var isGlobal: Bool { self == .open || self == .alternate }
}

struct ShortcutConfiguration: Codable, Equatable, Sendable {
    var open = ShortcutBinding(keyCode:49,modifiers:UInt32(cmdKey|shiftKey),keyLabel:"Space")
    var alternate: ShortcutBinding? = ShortcutBinding(keyCode:49,modifiers:UInt32(controlKey|optionKey),keyLabel:"Space")
    var search = ShortcutBinding(keyCode:3,modifiers:UInt32(cmdKey),keyLabel:"F")
    var previous = ShortcutBinding(keyCode:123,modifiers:0,keyLabel:"←")
    var next = ShortcutBinding(keyCode:124,modifiers:0,keyLabel:"→")
    var back = ShortcutBinding(keyCode:53,modifiers:0,keyLabel:"Esc")
    var settings = ShortcutBinding(keyCode:43,modifiers:UInt32(cmdKey),keyLabel:",")
    subscript(action:RecallShortcutAction)->ShortcutBinding? {
        get { switch action { case .open:open;case .alternate:alternate;case .search:search;case .previous:previous;case .next:next;case .back:back;case .settings:settings } }
        set {
            if action == .alternate { alternate = newValue; return }
            guard let newValue else { return }
            switch action { case .open:open = newValue;case .alternate:break;case .search:search = newValue;case .previous:previous = newValue;case .next:next = newValue;case .back:back = newValue;case .settings:settings = newValue }
        }
    }
    func validate() throws {
        var used = Set<String>()
        for action in RecallShortcutAction.allCases {
            guard let key = self[action] else { continue }
            try key.validate(global:action.isGlobal)
            guard used.insert(key.identity).inserted else { throw RewindError.message("\(key.label) is assigned to more than one action.") }
        }
    }
}
