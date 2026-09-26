import XCTest
@testable import Rewind

final class ArchiveDayLayoutTests:XCTestCase {
    private var calendar:Calendar {
        var value = Calendar(identifier:.gregorian);value.timeZone = TimeZone(identifier:"America/Los_Angeles")!;return value
    }
    private func date(_ day:Int,_ hour:Int = 12)->Date { calendar.date(from:DateComponents(year:2026,month:3,day:day,hour:hour))! }
    private func record(_ day:Int,_ hour:Int = 12,_ path:String = UUID().uuidString)->MemoryFrame {
        MemoryFrame(timestamp:date(day,hour),appName:"Calendar fixture",bundleID:"test",title:"",imagePath:path,text:"可复制文字",regions:[])
    }
    func testConsecutiveDaysPreserveMissingDaysAndDST() {
        let frames = [record(7),record(9),record(9,14)]
        let columns = ArchiveDayLayout.columns(frames:frames,around:date(8),calendar:calendar)
        XCTAssertEqual(columns.map { calendar.component(.day,from:$0.day) },[6,7,8,9,10])
        XCTAssertEqual(columns.map { $0.records.count },[0,1,0,2,0])
        XCTAssertEqual(columns.map(\.lane),[-2,-1,0,1,2])
        XCTAssertEqual(columns[3].day.timeIntervalSince(columns[2].day),23*3600)
        for column in columns { XCTAssertTrue(column.records.allSatisfy { calendar.isDate($0.timestamp,inSameDayAs:column.day) }) }
    }
    func testDayQueryExcludesDemoTrashAndDeduplicatesBeforeLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root)
        let before = record(7,23),midnight = record(8,0),after = record(9,0)
        for frame in [before,midnight,after,record(8,8,"same"),record(8,9,"same")] { try store.save(frame) }
        var demo = record(8);demo.demo = true;try store.save(demo)
        let trash = record(8,14);try store.save(trash);try store.moveToTrash(trash)
        let result = try store.archiveFrames(around:date(8),calendar:calendar)
        let columns = ArchiveDayLayout.columns(frames:result,around:date(8),calendar:calendar)
        XCTAssertEqual(columns.map { $0.records.count },[0,1,2,1,0])
        XCTAssertFalse(result.contains { $0.demo || $0.deletedAt != nil })
        XCTAssertTrue(columns[2].records.contains { $0.id == midnight.id })
        XCTAssertEqual(columns[2].records.first?.timestamp,date(8,9))
    }
    func testFeatureIsOptInAndPersistsWithoutBreakingOldSettings() throws {
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self,from:Data("{}".utf8)).glassArchiveEnabled)
        var settings = AppSettings();settings.glassArchiveEnabled = true
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(settings)).glassArchiveEnabled)
        settings.glassArchiveEnabled = false
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(settings)).glassArchiveEnabled)
    }
    func testFooterDrawingAndHitRegionsHaveOneBaselineAndEvenSpacing() {
        for width:CGFloat in [4.85,9.5,14.0] {
            let buttons = ArchiveFooterLayout.buttons(in:CGSize(width:width,height:1.0))
            XCTAssertEqual(buttons.map(\.action),["star","copy","rewind","close"])
            XCTAssertEqual(Set(buttons.map { $0.rect.midY }).count,1)
            XCTAssertEqual(Set(buttons.map { $0.rect.height }).count,1)
            XCTAssertEqual(Set(buttons.map { $0.rect.width }).count,1)
            for index in 1..<buttons.count { XCTAssertGreaterThan(buttons[index].rect.minX,buttons[index-1].rect.maxX) }
            XCTAssertGreaterThan(buttons[0].rect.minX,0)
            XCTAssertLessThan(buttons.last!.rect.maxX,width)
        }
    }
    func testExpandedCardFitsScreenshotWithoutPortraitLetterboxing() {
        for size in [CGSize(width:2000,height:876),CGSize(width:1440,height:900),CGSize(width:800,height:600)] {
            let span = 9*2.22/max(1,size.width/size.height)
            let card = ArchiveCardMetrics.expanded(aspect:1.6,viewport:size,verticalSpan:span)
            XCTAssertEqual(card.artwork.width/card.artwork.height,1.6,accuracy:0.0001)
            XCTAssertEqual(card.height-card.artwork.height,ArchiveCardMetrics.verticalChrome,accuracy:0.0001)
            XCTAssertEqual(card.width/2-card.artwork.maxX,ArchiveCardMetrics.inset,accuracy:0.0001)
            XCTAssertEqual(card.height/2-card.artwork.maxY,ArchiveCardMetrics.inset,accuracy:0.0001)
            XCTAssertEqual(card.footer.minY+card.height/2,ArchiveCardMetrics.inset,accuracy:0.0001)
            XCTAssertEqual(card.footer.minX,card.artwork.minX,accuracy:0.0001)
            XCTAssertEqual(card.footer.maxX,card.artwork.maxX,accuracy:0.0001)
            XCTAssertEqual(card.artwork.minY-card.footer.maxY,ArchiveCardMetrics.contentGap,accuracy:0.0001)
            XCTAssertGreaterThan(card.artwork.width,4.87*1.3)
            XCTAssertLessThanOrEqual(card.width,span*size.width/size.height*0.88+0.001)
            XCTAssertLessThanOrEqual(card.height,span*0.76+0.001)
            let center = size.height/2+ArchiveViewportLayout.extractionCenterY(in:size,verticalSpan:span)*size.height/span
            let halfHeight = card.height*size.height/span/2
            XCTAssertGreaterThanOrEqual(center-halfHeight,ArchiveViewportLayout.timelineHeight+16-0.001,"Native timeline input must not intercept footer buttons")
            XCTAssertLessThanOrEqual(center+halfHeight,size.height-116+0.001)
        }
    }
}
