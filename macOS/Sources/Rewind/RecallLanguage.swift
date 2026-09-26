import Foundation

/// Recall's interface is English; recorded content and search input retain
/// their original language. Formatting keeps the user's local time zone.
enum RecallLanguage {
    static let locale = Locale(identifier:"en_US")
}

extension Date {
    func recallFormatted(date:Date.FormatStyle.DateStyle,time:Date.FormatStyle.TimeStyle)->String {
        formatted(Date.FormatStyle(date:date,time:time).locale(RecallLanguage.locale))
    }
    func recallFormatted(_ style:Date.FormatStyle)->String {
        formatted(style.locale(RecallLanguage.locale))
    }
}
