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

struct ArchiveCardMetrics {
    let width:CGFloat
    let height:CGFloat
    let artwork:CGRect
    static func make(width:CGFloat,height:CGFloat,aspect:CGFloat)->Self {
        let ratio = max(0.15,aspect)
        let artWidth = min(width-0.48,(height-1.4)*ratio)
        let artHeight = artWidth/ratio
        return Self(width:width,height:height,artwork:CGRect(x:-artWidth/2,y:height/2-0.20-artHeight,width:artWidth,height:artHeight))
    }
    static func expanded(aspect:CGFloat,viewport:CGSize,verticalSpan:CGFloat)->Self {
        let maxHeight = verticalSpan*0.76
        let maxWidth = verticalSpan*max(1,viewport.width/max(1,viewport.height))*0.88
        let artWidth = min(maxWidth-0.48,(maxHeight-1.4)*max(0.15,aspect))
        return make(width:artWidth+0.48,height:artWidth/max(0.15,aspect)+1.4,aspect:aspect)
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
