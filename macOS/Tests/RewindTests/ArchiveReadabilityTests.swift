import XCTest
import AppKit
import SceneKit
@testable import Rewind

final class ArchiveReadabilityTests:XCTestCase {
    @MainActor func testFooterSymbolsUseExplicitInkInBothAppearances() throws {
        for name in ["star","doc.on.doc","arrow.up.right","arrow.up.left.and.arrow.down.right"] {
            for night in [false,true] {
                let ink = NSColor(white:night ? 0.98:0.10,alpha:1)
                let icon = try XCTUnwrap(ArchiveGlassScene.footerSymbol(name,ink:ink))
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(icon.tiffRepresentation)))
                var total:CGFloat = 0,count:CGFloat = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        if let color = bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),color.alphaComponent > 0.5 {
                            total += (color.redComponent+color.greenComponent+color.blueComponent)/3;count += 1
                        }
                    }
                }
                XCTAssertGreaterThan(count,10)
                if night { XCTAssertGreaterThan(total/max(1,count),0.85,"Dark footer icons must not render black") }
                else { XCTAssertLessThan(total/max(1,count),0.25,"Light footer icons must retain contrast") }
            }
        }
    }
    @MainActor func testHitCardOwnsSummitFocusAndHighlight() throws {
        let day = Calendar.current.startOfDay(for:Date())
        let frames = (0..<16).map { index in
            MemoryFrame(timestamp:day.addingTimeInterval(Double(index)*60),appName:"Hit target",bundleID:"test",title:"",imagePath:"\(index).png",text:"",regions:[])
        }
        let scene = ArchiveGlassScene(),target = frames[5]
        scene.update(frames:frames,images:[:],appearance:.deepNight,selected:nil,size:CGSize(width:1440,height:900),reduced:false,day:day)
        // The old fixed-plane projection would aim into another column.
        scene.pointer(rayNear:SCNVector3(12,15,-1),rayFar:SCNVector3(12,-15,-1),recordID:target.id)
        for _ in 0..<240 { scene.advance(dt:1/60) }
        let rack = try XCTUnwrap(scene.scene.rootNode.childNode(withName:"racks",recursively:false))
        let summit = try XCTUnwrap(rack.childNodes.max { $0.position.y < $1.position.y })
        XCTAssertEqual(summit.name,target.id)
        XCTAssertEqual(scene.hoveredID,target.id)
        XCTAssertNotNil(summit.childNode(withName:"hover-outline",recursively:false))
        XCTAssertEqual(scene.cameraNode.camera!.focusDistance,Double(-scene.cameraNode.convertPosition(summit.worldPosition,from:nil).z),accuracy:0.01)
        scene.hover(nil)
        XCTAssertNil(rack.childNode(withName:"hover-outline",recursively:true))
        scene.stopMotion()
    }

    @MainActor func testNativeClickKeepsHighlightedRecordAfterWaveMoves() throws {
        let day = Calendar.current.startOfDay(for:Date())
        let frames = (0..<24).map { index in
            MemoryFrame(timestamp:day.addingTimeInterval(Double(index)*60),appName:"Hit target",bundleID:"test",title:"",imagePath:"\(index).png",text:"",regions:[])
        }
        let archive = ArchiveGlassScene(),size = CGSize(width:1440,height:900)
        archive.update(frames:frames,images:[:],appearance:.warmDay,selected:nil,size:size,reduced:false,day:day)
        let native = ArchiveSceneView(frame:CGRect(origin:.zero,size:size))
        native.scene = archive.scene;native.pointOfView = archive.cameraNode;native.archive = archive
        native.onPointer = { near,far,id in archive.pointer(rayNear:near,rayFar:far,recordID:id) }
        native.onHover = { archive.hover($0) }
        let window = NSWindow(contentRect:native.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = native
        defer { window.orderOut(nil);archive.stopMotion() }
        _ = native.snapshot()
        var candidate:(CGPoint,String)?
        scan:for y in stride(from:180.0,through:720.0,by:40) {
            for x in stride(from:240.0,through:1200.0,by:40) {
                let point = CGPoint(x:x,y:y)
                var node = native.hitTest(point,options:[.searchMode:SCNHitTestSearchMode.closest.rawValue,.categoryBitMask:1]).first?.node
                while let current = node {
                    if let id = current.name,archive.recordIDs.contains(id) { candidate = (point,id);break scan }
                    node = current.parent
                }
            }
        }
        let (point,id) = try XCTUnwrap(candidate,"Find an actual record face, not an empty sleeve")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with:.mouseMoved,location:native.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:0))
        native.mouseMoved(with:event)
        XCTAssertEqual(archive.hoveredID,id)
        for _ in 0..<240 { archive.advance(dt:1/60) }
        let rack = try XCTUnwrap(archive.scene.rootNode.childNode(withName:"racks",recursively:false))
        XCTAssertEqual(rack.childNodes.max { $0.position.y < $1.position.y }?.name,id)
        var clicked:String?
        native.onSelect = { clicked = $0 }
        native.mouseDown(with:event);native.mouseUp(with:event)
        XCTAssertEqual(clicked,id,"A wave must not substitute a neighbour beneath the stationary pointer")
        let drag = try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDragged,location:native.convert(CGPoint(x:point.x,y:point.y-30),to:nil),modifierFlags:[],timestamp:1,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:0))
        native.mouseDown(with:event);native.mouseDragged(with:drag);native.mouseUp(with:drag)
        XCTAssertNil(archive.hoveredID,"Dragging the rack invalidates the old pointer target")
        XCTAssertNil(rack.childNode(withName:"hover-outline",recursively:true))
        XCTAssertEqual(clicked,id,"Dragging must not select another card")
        archive.hover(id)
        archive.scroll(by:10,precise:false)
        XCTAssertNil(archive.hoveredID,"Camera scrolling invalidates the old summit highlight")
    }

    @MainActor func testFinalPointerSampleIsDeliveredAndExitCancelsPendingSample() async throws {
        let view = ArchiveSceneView(frame:NSRect(x:0,y:0,width:900,height:600))
        var delivered = 0
        view.onPointer = { _,_,_ in delivered += 1 }
        func move(_ x:CGFloat)->NSEvent {
            NSEvent.mouseEvent(with:.mouseMoved,location:NSPoint(x:x,y:300),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:0,pressure:0)!
        }
        view.mouseMoved(with:move(450));view.mouseMoved(with:move(451))
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(delivered,2,"The last small movement must not be dropped by the hit-test throttle")
        view.mouseMoved(with:move(452));view.mouseMoved(with:move(453))
        view.mouseExited(with:move(453))
        let beforeExit = delivered
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(delivered,beforeExit,"A delayed sample must not restore hover after the mouse exits")
    }
}
