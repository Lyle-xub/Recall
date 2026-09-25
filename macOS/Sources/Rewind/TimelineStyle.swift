import SwiftUI

@MainActor enum TimelineClock {
    private static let time:DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier:"en_US_POSIX"); value.dateFormat = "HH:mm:ss"; return value
    }()
    static func range(_ start:Date,_ end:Date) -> String { time.string(from:start)+" – "+time.string(from:end) }
}

enum TimelineZoom {
    static let minimum = 60.0
    static let maximum = 86_400.0
    static let presets = [60.0,300,900,3600,21600,86400]
    static func clamp(_ span:Double) -> Double { span.isFinite ? min(maximum,max(minimum,span)):300 }
    static func tickStep(for span:Double) -> Double {
        [5.0,10,15,30,60,120,300,600,900,1800,3600,7200,14400,21600].first { $0 >= span/8 } ?? 21600
    }
    static func durationLabel(_ seconds:Double) -> String {
        if seconds < 1 { return "<1 sec" }
        if seconds < 60 { return "\(Int(seconds)) sec" }
        if seconds < 3600 {
            let minutes = seconds/60
            return minutes == minutes.rounded() ? "\(Int(minutes)) min":String(format:"%.1f min",minutes)
        }
        let hours = seconds/3600
        return hours == hours.rounded() ? "\(Int(hours)) hr":String(format:"%.1f hr",hours)
    }
}

@MainActor enum TimelinePalette {
    private static var colors:[String:Color] = [:]
    static func color(for segment:AppTimeSegment) -> Color {
        guard let kind = segment.kind else { return .primary.opacity(0.12) }
        if kind == .excluded || kind == .unavailable { return .primary.opacity(0.20) }
        let key = segment.bundleID.isEmpty ? segment.appName:segment.bundleID
        if let color = colors[key] { return color }
        guard let icon = AppIconCache.image(name:segment.appName,bundleID:segment.bundleID),
              let image = icon.cgImage(forProposedRect:nil,context:nil,hints:nil),
              let tint = IconColorSampler.sample(image) else { return .secondary.opacity(0.65) }
        let color = tint.isNeutral ? Color.primary.opacity(0.58):Color(red:tint.red,green:tint.green,blue:tint.blue)
        colors[key] = color
        return color
    }
}

enum TimelineBlurProfile {
    /// Transparent margin and zero slope at both ends prevent a visible top seam.
    static func opacity(at fraction:Double) -> Double {
        let t = min(1,max(0,(fraction-0.18)/0.82))
        return t*t*t*(t*(t*6-15)+10)
    }
}
