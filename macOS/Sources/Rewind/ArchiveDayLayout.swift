import Foundation
import CoreGraphics

/// Calendar arithmetic, rather than 86,400-second offsets, keeps local days
/// intact through daylight-saving changes. Blank slots have no record identity.
struct ArchiveDayColumn {
    let day:Date
    let lane:Int
    let records:[MemoryFrame]
}
enum ArchiveDayLayout {
    static let recordsPerDay = 48
    static func columns(frames:[MemoryFrame],around anchor:Date,calendar:Calendar = .current)->[ArchiveDayColumn] {
        let center = calendar.startOfDay(for:anchor)
        let grouped = Dictionary(grouping:frames.filter { !$0.demo && $0.deletedAt == nil }) { calendar.startOfDay(for:$0.timestamp) }
        return (-2...2).map { lane in
            let day = calendar.date(byAdding:.day,value:lane,to:center)!
            var seen = Set<String>()
            let records = (grouped[day] ?? []).sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id:$0.timestamp > $1.timestamp }
                .filter { seen.insert($0.imagePath).inserted }
            return ArchiveDayColumn(day:day,lane:lane,records:Array(records.prefix(recordsPerDay)))
        }
    }
}

/// Native timeline input and extracted cards share the same safe area. The
/// transparent part of a separate NSPanel must not cover the card's buttons.
enum ArchiveViewportLayout {
    static let timelineHeight:CGFloat = 164
    static func cardArea(in size:CGSize)->CGRect {
        let top:CGFloat = 116,bottom = timelineHeight+16
        return CGRect(x:size.width*0.06,y:bottom,width:size.width*0.88,height:max(1,size.height-top-bottom))
    }
    static func extractionCenterY(in size:CGSize,verticalSpan:CGFloat)->CGFloat {
        (cardArea(in:size).midY-size.height/2)*verticalSpan/max(1,size.height)
    }
}

struct ArchiveCardMetrics {
    static let inset:CGFloat = 0.20
    static let contentGap:CGFloat = 0.14
    static let footerHeight:CGFloat = 1.0
    static var verticalChrome:CGFloat { inset*2+contentGap+footerHeight }
    let width:CGFloat
    let height:CGFloat
    let artwork:CGRect
    let footer:CGRect
    static func make(width:CGFloat,height:CGFloat,aspect:CGFloat)->Self {
        let ratio = max(0.15,aspect)
        let artWidth = min(width-inset*2,(height-verticalChrome)*ratio)
        let artHeight = artWidth/ratio
        return Self(width:width,height:height,
            artwork:CGRect(x:-artWidth/2,y:height/2-inset-artHeight,width:artWidth,height:artHeight),
            footer:CGRect(x:-width/2+inset,y:-height/2+inset,width:width-inset*2,height:footerHeight))
    }
    static func expanded(aspect:CGFloat,viewport:CGSize,verticalSpan:CGFloat)->Self {
        let maxHeight = min(verticalSpan*0.76,ArchiveViewportLayout.cardArea(in:viewport).height*verticalSpan/max(1,viewport.height))
        let maxWidth = verticalSpan*max(1,viewport.width/max(1,viewport.height))*0.88
        let artWidth = min(maxWidth-inset*2,(maxHeight-verticalChrome)*max(0.15,aspect))
        return make(width:artWidth+inset*2,height:artWidth/max(0.15,aspect)+verticalChrome,aspect:aspect)
    }
}

/// Drawing and hit testing consume these same rectangles so all four actions
/// share a baseline, height, width and gap at every card size.
enum ArchiveFooterLayout {
    static let actions = ["star","copy","rewind","close"]
    static func buttons(in size:CGSize)->[(action:String,rect:CGRect)] {
        let padding = size.width*0.012,gap = size.width*0.01
        let width = (size.width-2*padding-3*gap)/4
        return actions.enumerated().map { index,action in
            (action,CGRect(x:padding+CGFloat(index)*(width+gap),y:size.height*0.055,width:width,height:size.height*0.49))
        }
    }
}
