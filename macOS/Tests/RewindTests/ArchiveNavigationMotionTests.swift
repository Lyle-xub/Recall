import XCTest
import AppKit
import SceneKit
import SwiftUI
@testable import Rewind

final class ArchiveNavigationMotionTests:XCTestCase {
    @MainActor func testMountedSwiftUIArchiveMovesThenLoadsAndExtractsFinalPixels()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(root:root),day=Calendar.current.startOfDay(for:Date()).addingTimeInterval(-86400*4)
        let bitmap=try XCTUnwrap(CGContext(data:nil,width:160,height:100,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red:0.2,green:0.7,blue:0.3,alpha:1));bitmap.fill(CGRect(x:0,y:0,width:160,height:100))
        let png=try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(bitmap.makeImage())).representation(using:.png,properties:[:]))
        let items=(0..<600).map {i in MemoryFrame(id:"host-motion-\(i)",timestamp:day.addingTimeInterval(Double(36000-i*30)),appName:"Synthetic",bundleID:"test",title:"Row \(i)",imagePath:"frames/\(i).png",text:"",regions:[])}
        for item in items {try model.store.save(item);try png.write(to:root.appendingPathComponent(item.imagePath))}
        model.settings.glassArchiveEnabled=true;model.archiveDay=day;model.reload()
        // Load a different page first so the actual mounted window, not just
        // the model's covered-row bookkeeping, starts at row 20.
        model.requestArchiveWindow(at:300);await model.waitForPendingLoads()
        model.requestArchiveWindow(at:20);await model.waitForPendingLoads()
        let extracted=expectation(description:"Real mounted archive extracts the latest record after camera arrival")
        var opened:[String]=[]
        // This test controls an animation clock; CI may enable Reduce Motion.
        // Its read-only facade has an SDK-exported writable backing value.
        // Override only this host, leaving system preferences untouched.
        let host=NSHostingView(rootView:ArchiveMotionHost(model:model,onFocus:{id in if let id {opened.append(id);extracted.fulfill()}})
            .environment(\._accessibilityReduceMotion,false))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:800),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.level = .statusBar;window.contentView=host;window.orderFront(nil)
        defer {window.close()}
        func find(_ view:NSView)->ArchiveSceneView? {if let archive=view as? ArchiveSceneView {return archive};return view.subviews.compactMap(find).first}
        host.layoutSubtreeIfNeeded()
        let native=try XCTUnwrap(find(host)),scene=try XCTUnwrap(native.archive)
        scene.advance(dt:1,immediate:true)
        XCTAssertEqual(scene.scrollOffset,20,accuracy:0.001)
        let startZ=scene.cameraNode.position.z,initialIDs=Set(model.archiveFrames.map(\.id))
        let firstPixels=expectation(description:"Destination pixels reach the mounted renderer during the journey")
        let began=ContinuousClock.now
        var pixelTime:ContinuousClock.Instant?,pixelRow:CGFloat?,holdMotion=true
        scene.onWorkMeasured={ [weak scene] _,_ in
            guard let scene else {return}
            // Hold only the initial clock, not SwiftUI updates or image work.
            // Destination preparation must work without intermediate paging;
            // this asserts causality rather than a machine-speed deadline.
            if holdMotion {scene.stopMotion()}
            guard pixelTime == nil,scene.hasPreparedImage(at:items[550].imagePath) else {return}
            pixelTime = .now;pixelRow=scene.scrollOffset;firstPixels.fulfill()
        }
        model.beginTimelineDrag();model.scrub(to:items[550].timestamp);await model.waitForPendingLoads()
        XCTAssertFalse(initialIDs.isDisjoint(with:Set(model.archiveFrames.map(\.id))),"Resolving the destination keeps the screenshots currently on screen")
        XCTAssertNil(model.archiveExtractionID)
        await fulfillment(of:[firstPixels],timeout:10)
        XCTAssertEqual(try XCTUnwrap(pixelRow),20,accuracy:0.001)
        XCTAssertFalse(model.archiveFrames.contains {$0.id == items[550].id},"Prepared pixels arrive without replacing the mounted source page")
        holdMotion=false
        model.scrub(to:items[530].timestamp);await model.waitForPendingLoads();model.endTimelineDrag()
        let destination=try XCTUnwrap(model.archiveNavigationTarget)
        XCTAssertEqual(destination.recordID,items[530].id)
        await fulfillment(of:[extracted],timeout:20)
        XCTAssertEqual(opened,[items[530].id]);XCTAssertEqual(model.archiveExtractionID,items[530].id)
        XCTAssertEqual(scene.cameraNode.position.z,startZ+510,accuracy:0.01)
        print("ARCHIVE_DESTINATION_MOUNTED controlled-preparation-row20-to550-retarget530 first-pixels=\(began.duration(to:try XCTUnwrap(pixelTime))) pixel-row=\(try XCTUnwrap(pixelRow)) extracted=\(began.duration(to:.now))")
        scene.onWorkMeasured=nil
        XCTAssertLessThanOrEqual(scene.residentNodeCount,262)
        XCTAssertTrue(model.archiveWindow.columns.allSatisfy {$0.records.count <= 96})
        model.returnToDesktop();scene.setActive(false)
        model.prepareToQuit();await model.shutDownRecording();await model.storageOptimizer.stop()
    }
    @MainActor func testNativeCameraMovesThroughIntermediatePagesBeforeOpeningLatestCard()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root),day=Calendar.current.startOfDay(for:Date()).addingTimeInterval(-86400*4)
        let records=(0..<600).map {i in MemoryFrame(id:"motion-\(i)",timestamp:day.addingTimeInterval(Double(36000-i*30)),appName:"Synthetic",bundleID:"test",title:"Row \(i)",imagePath:"frames/\(i).png",text:"",regions:[])}
        for frame in records {try store.save(frame)}
        let scene=ArchiveGlassScene(),view=ArchiveSceneView(frame:NSRect(x:0,y:0,width:1200,height:800))
        let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=view
        view.scene=scene.scene;view.pointOfView=scene.cameraNode;view.archive=scene
        scene.attachAnimation(to:view)
        defer {scene.setActive(false);window.close()}
        var page=try store.archiveWindow(ArchiveWindowQuery(day:day)),target:ArchiveNavigationTarget?
        func update() {
            scene.update(frames:page.frames,images:[:],appearance:.warmDay,selected:nil,size:view.bounds.size,reduced:false,day:day,timelinePosition:target?.date,window:page,navigation:target)
            scene.stopMotion()
        }
        update();scene.advance(dt:1,immediate:true)
        let initial=scene.cameraNode.position
        var demands:[Double]=[],settled:[ArchiveNavigationTarget]=[]
        scene.onNavigationWindowDemand={row,destination in
            demands.append(row)
            page=try! store.archiveWindow(ArchiveWindowQuery(day:day,row:row,epoch:destination.generation))
            update()
        }
        scene.onNavigationSettled={settled.append($0)}
        func navigate(_ row:Int,_ generation:Int)throws {
            page=try store.archiveWindow(ArchiveWindowQuery(day:day,near:records[row].timestamp,epoch:generation))
            target=ArchiveNavigationTarget(generation:generation,date:records[row].timestamp,row:Double(row),recordID:records[row].id)
            update()
        }
        try navigate(550,1)
        XCTAssertEqual(scene.cameraNode.position.z,initial.z,accuracy:0.0001,"Resolving a far page must not teleport the camera")
        scene.advance(dt:1/60)
        XCTAssertGreaterThan(scene.scrollOffset,0);XCTAssertLessThan(scene.scrollOffset,550)
        XCTAssertTrue(settled.isEmpty);XCTAssertNil(scene.selectionSurface())
        for _ in 0..<8 {scene.advance(dt:1/60)}
        let moving=scene.cameraNode.position
        try navigate(80,2)
        XCTAssertEqual(scene.cameraNode.position.z,moving.z,accuracy:0.0001,"Reversing preserves the displayed pose")
        for _ in 0..<900 {
            scene.advance(dt:1/60)
            XCTAssertLessThanOrEqual(scene.residentNodeCount,262)
            if !settled.isEmpty {break}
        }
        XCTAssertEqual(settled.map(\.generation),[2])
        XCTAssertEqual(scene.scrollOffset,80,accuracy:0.001)
        XCTAssertTrue(demands.contains {$0 > 80 && $0 < 550},"Continuous motion must page intermediate rows")
        XCTAssertTrue(scene.recordIDs.contains(records[80].id))
        scene.update(frames:page.frames,images:[:],appearance:.warmDay,selected:records[80].id,size:view.bounds.size,reduced:false,day:day,timelinePosition:target?.date,window:page,navigation:target)
        XCTAssertEqual(scene.cameraNode.position.z,initial.z+80,accuracy:0.001)
        for _ in 0..<600 {scene.advance(dt:1/60);if scene.selectionSurface() != nil {break}}
        XCTAssertEqual(scene.selectionSurface()?.0.id,records[80].id)
    }

    @MainActor func testCrossDayRetainsPhysicalCardPoseAndReducedMotionSettlesOnce()throws {
        let day=Calendar.current.startOfDay(for:Date()).addingTimeInterval(-86400*3),next=day.addingTimeInterval(86400)
        let items=[MemoryFrame(id:"first",timestamp:day.addingTimeInterval(100),appName:"Test",bundleID:"",title:"",imagePath:"a",text:"",regions:[]),MemoryFrame(id:"next",timestamp:next.addingTimeInterval(100),appName:"Test",bundleID:"",title:"",imagePath:"b",text:"",regions:[])]
        let scene=ArchiveGlassScene(),size=CGSize(width:1200,height:800)
        defer {scene.setActive(false)}
        var window=ArchiveWindow(columns:ArchiveDayLayout.columns(frames:items,around:day),epoch:1,focusRow:0)
        scene.update(frames:items,images:[:],appearance:.warmDay,selected:nil,size:size,reduced:true,day:day,window:window)
        let node=try XCTUnwrap(scene.scene.rootNode.childNode(withName:"next",recursively:true)),before=node.position
        let target=ArchiveNavigationTarget(generation:2,date:items[1].timestamp,row:0,recordID:"next")
        window=ArchiveWindow(columns:ArchiveDayLayout.columns(frames:items,around:next),epoch:2,focusRow:0)
        scene.update(frames:items,images:[:],appearance:.warmDay,selected:nil,size:size,reduced:false,day:next,timelinePosition:target.date,window:window,navigation:target)
        XCTAssertTrue(node === scene.scene.rootNode.childNode(withName:"next",recursively:true))
        XCTAssertEqual(node.position.x,before.x,accuracy:0.0001)
        scene.advance(dt:1/60)
        XCTAssertLessThan(node.position.x,before.x);XCTAssertGreaterThan(node.position.x,0)
        var completed:[Int]=[];scene.onNavigationSettled={completed.append($0.generation)}
        scene.advance(dt:1,immediate:true);scene.advance(dt:1,immediate:true)
        XCTAssertEqual(completed,[2]);XCTAssertEqual(node.position.x,0,accuracy:0.001)
        scene.setActive(false);scene.advance(dt:1,immediate:true)
        XCTAssertEqual(completed,[2],"Inactive scenes cannot revive old navigation")
    }
}

private struct ArchiveMotionHost:View {
    @ObservedObject var model:AppModel
    let onFocus:(String?)->Void
    @State private var focus:String?
    var body:some View {
        ArchiveStackView(model:model,focusedID:$focus)
            .onChange(of:focus) {_,id in onFocus(id)}
            .onChange(of:model.archiveTimelinePosition) {_,_ in focus=nil}
            .onChange(of:model.timelineDragging) {_,dragging in if dragging {focus=nil}}
    }
}
