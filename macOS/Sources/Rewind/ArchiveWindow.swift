import Foundation

struct ArchivePageAnchor:Sendable {
    let day:Date
    let id:String
    let timestamp:Date
    let row:Int
}
struct ArchivePinnedRecord:Sendable {
    var frame:MemoryFrame
    let day:Date
    let lane:Int
    let row:Int
}
struct ArchiveWindowQuery:Sendable {
    let day:Date
    var row:Double = 0
    var near:Date?
    var anchors:[ArchivePageAnchor] = []
    var epoch:Int = 0
    var pins:[ArchivePinnedRecord] = []
}
struct ArchiveWindow:Sendable {
    var columns:[ArchiveDayColumn] = []
    var epoch:Int = 0
    var focusRow:Double?
    var pins:[ArchivePinnedRecord] = []
    var frames:[MemoryFrame] {
        let loaded=columns.flatMap(\.records),ids=Set(loaded.map(\.id))
        return loaded+pins.filter {!ids.contains($0.frame.id)}.map(\.frame)
    }
    var minimumRow:Int {min(0,columns.map(\.origin).min() ?? 0)}
    func anchors(near row:Double)->[ArchivePageAnchor] {
        columns.compactMap { column in
            guard !column.records.isEmpty else {return nil}
            let index=max(0,min(column.records.count-1,Int(row)-column.origin-column.startIndex))
            let frame=column.records[index]
            return ArchivePageAnchor(day:column.day,id:frame.id,timestamp:frame.timestamp,row:column.origin+column.startIndex+index)
        }
    }
    func covers(_ row:Double)->Bool {
        !columns.isEmpty && columns.allSatisfy { column in
            guard column.totalCount > 0 else {return true}
            let center=max(0,min(column.totalCount-1,Int(row)-column.origin))
            let first=max(0,center-ArchiveDayLayout.renderedRows/2)
            let last=min(column.totalCount,center+ArchiveDayLayout.renderedRows/2+1)
            return column.startIndex <= first && column.startIndex+column.records.count >= last
        }
    }
}
