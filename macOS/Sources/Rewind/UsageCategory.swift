import SwiftUI

/// One stable palette is shared by every usage chart, legend, and app row.
enum UsageCategory:String,CaseIterable {
    case productivity = "Productivity", communication = "Communication", creativity = "Creativity"
    case tools = "Utilities", entertainment = "Entertainment", education = "Education", other = "Other", privateActivity = "Private activity"
    var rgb:(red:Double,green:Double,blue:Double) { switch self {
        case .productivity: (0.16,0.39,0.82)
        case .communication: (0.00,0.57,0.55)
        case .creativity: (0.57,0.28,0.77)
        case .tools: (0.90,0.45,0.10)
        case .entertainment: (0.85,0.22,0.48)
        case .education: (0.42,0.55,0.10)
        case .other: (0.48,0.34,0.24)
        case .privateActivity: (0.33,0.40,0.49)
    } }
    var color:Color { Color(red:rgb.red,green:rgb.green,blue:rgb.blue) }
    var symbol:String { switch self {
        case .productivity: "briefcase.fill"
        case .communication: "bubble.left.and.bubble.right.fill"
        case .creativity: "paintpalette.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .entertainment: "play.rectangle.fill"
        case .education: "graduationcap.fill"
        case .other: "square.grid.2x2.fill"
        case .privateActivity: "lock.fill"
    } }
    @MainActor private static var cache:[String:Self] = [:]
    @MainActor static func resolve(_ app:AppUsageIdentity) -> Self {
        if app.kind == .excluded { return .privateActivity }
        if let cached = cache[app.bundleID] { return cached }
        let category = NSWorkspace.shared.urlForApplication(withBundleIdentifier:app.bundleID)
            .flatMap { Bundle(url:$0)?.object(forInfoDictionaryKey:"LSApplicationCategoryType") as? String } ?? ""
        let value:Self
        if category.contains("productivity") || category.contains("business") || category.contains("finance") { value = .productivity }
        else if category.contains("social") { value = .communication }
        else if ["design","photography","music","video","graphics"].contains(where:category.contains) { value = .creativity }
        else if category.contains("utilities") || category.contains("developer") { value = .tools }
        else if category.contains("games") || category.contains("entertainment") { value = .entertainment }
        else if category.contains("education") || category.contains("reference") { value = .education }
        else { value = .other }
        cache[app.bundleID] = value; return value
    }
}
