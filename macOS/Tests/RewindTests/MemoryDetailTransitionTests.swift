import XCTest
import SwiftUI
import AppKit
@testable import Rewind

final class MemoryDetailTransitionTests:XCTestCase {
    private func picture()->NSImage {
        let bitmap=CGContext(data:nil,width:320,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(red:0.2,green:0.6,blue:0.8,alpha:1));bitmap.fill(CGRect(x:0,y:0,width:320,height:200))
        return NSImage(cgImage:bitmap.makeImage()!,size:NSSize(width:320,height:200))
    }
    @MainActor func testNativeImageFrameAndRadiusTravelContinuouslyAndReverseWithoutRecreatingSurface()throws {
        let native=MemoryImageTransitionView(frame:NSRect(x:0,y:0,width:1000,height:800))
        let window=NSWindow(contentRect:native.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=native
        defer {native.stop();window.close()}
        let image=picture(),start=CGRect(x:500,y:400,width:240,height:150),destination=CGRect(x:50,y:80,width:800,height:500)
        let source=MemoryImageTransitionSource(id:"image",image:image,rectInWindow:native.convert(start,to:nil),radius:19)
        let surface=native.image
        var completions:[Int]=[];native.onSettled={completions.append($0)}
        native.update(id:"image",url:URL(fileURLWithPath:"/synthetic-missing.png"),regions:[],destination:destination,source:source,radius:14,reduced:false)
        XCTAssertEqual(native.image.frame,start);XCTAssertTrue(native.image === surface)
        native.advance(by:0.12)
        let midpoint=native.image.frame
        XCTAssertGreaterThan(midpoint.width,start.width);XCTAssertLessThan(midpoint.width,destination.width)
        XCTAssertLessThan(midpoint.minX,start.minX);XCTAssertGreaterThan(midpoint.minX,destination.minX)
        XCTAssertGreaterThan(native.image.cornerRadius,14);XCTAssertLessThan(native.image.cornerRadius,19)
        XCTAssertTrue(completions.isEmpty)
        native.update(id:"image",url:URL(fileURLWithPath:"/synthetic-missing.png"),regions:[],destination:start,source:nil,radius:22,reduced:false)
        XCTAssertEqual(native.image.frame,midpoint,"Reversal begins at the actual in-flight rectangle")
        native.advance(by:MemoryImageFlight.duration)
        XCTAssertEqual(native.image.frame,start);XCTAssertEqual(native.image.cornerRadius,22)
        XCTAssertTrue(native.image === surface);XCTAssertEqual(completions.count,1)
        native.update(id:"image",url:URL(fileURLWithPath:"/synthetic-missing.png"),regions:[],destination:destination,source:nil,radius:14,reduced:false)
        native.advance(by:0.1);native.stop();native.advance(by:1)
        XCTAssertEqual(completions.count,1,"Dismantled or cancelled motion cannot publish old completion")
        native.update(id:"image",url:URL(fileURLWithPath:"/synthetic-missing.png"),regions:[],destination:destination,source:nil,radius:14,reduced:true)
        XCTAssertEqual(native.image.frame,destination);XCTAssertNil(native.flight)
    }

    @MainActor func testNativeImageClickOpensButOCRSelectionAndDraggingDoNot()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let image=picture(),url=root.appendingPathComponent("image.png")
        try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation))?.representation(using:.png,properties:[:])).write(to:url)
        let native=MemoryImageTransitionView(frame:NSRect(x:0,y:0,width:800,height:600))
        let window=NSWindow(contentRect:native.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=native
        defer {native.stop();window.close()}
        let loaded=expectation(description:"The same native image has real pixels and OCR")
        native.image.onImageSize={_ in loaded.fulfill()}
        let region=TextRegion(text:"Select these words",x:0.1,y:0.1,width:0.7,height:0.2)
        native.update(id:"record",url:url,regions:[region],destination:CGRect(x:50,y:50,width:640,height:400),source:nil,radius:22,reduced:true)
        await fulfillment(of:[loaded],timeout:5)
        native.image.layoutSubtreeIfNeeded()
        var opened=0;native.image.onOpen={opened += 1}
        func find(_ view:NSView)->IndexedTextOverlay? {if let overlay=view as? IndexedTextOverlay {return overlay};return view.subviews.compactMap(find).first}
        let overlay=try XCTUnwrap(find(native.image));overlay.layoutSubtreeIfNeeded()
        func event(_ point:NSPoint,_ kind:NSEvent.EventType)->NSEvent {
            NSEvent.mouseEvent(with:kind,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        let textStart=overlay.convert(NSPoint(x:80,y:60),to:nil),textEnd=overlay.convert(NSPoint(x:420,y:60),to:nil)
        let hit=try XCTUnwrap(native.image.hitTest(native.convert(textStart,from:nil)))
        XCTAssertTrue(hit === overlay)
        hit.mouseDown(with:event(textStart,.leftMouseDown));hit.mouseDragged(with:event(textEnd,.leftMouseDragged));hit.mouseUp(with:event(textEnd,.leftMouseUp))
        XCTAssertFalse(overlay.selectedText.isEmpty);XCTAssertEqual(opened,0)
        let empty=overlay.convert(NSPoint(x:400,y:320),to:nil)
        let background=try XCTUnwrap(native.image.hitTest(native.convert(empty,from:nil)))
        XCTAssertTrue(background === native.image)
        background.mouseDown(with:event(empty,.leftMouseDown));background.mouseUp(with:event(empty,.leftMouseUp))
        XCTAssertEqual(opened,1)
        func imageView(_ view:NSView)->NSImageView? {if let picture=view as? NSImageView {return picture};return view.subviews.compactMap(imageView).first}
        let pictureView=try XCTUnwrap(imageView(native.image))
        XCTAssertEqual(pictureView.accessibilityRole(),.button)
        XCTAssertTrue(pictureView.accessibilityLabel()?.contains("Open recording details") == true)
        XCTAssertTrue(pictureView.accessibilityPerformPress());XCTAssertEqual(opened,2)
        let enter=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36))
        pictureView.keyDown(with:enter);XCTAssertEqual(opened,3)
        background.mouseDown(with:event(empty,.leftMouseDown));background.mouseDragged(with:event(NSPoint(x:empty.x+30,y:empty.y),.leftMouseDragged));background.mouseUp(with:event(empty,.leftMouseUp))
        XCTAssertEqual(opened,3)
    }

    @MainActor func testCancelledDecodeForSameURLRestartsAndNoOpGeometryStillAcknowledgesCompletion()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let image=picture(),url=root.appendingPathComponent("same.png")
        try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation))?.representation(using:.png,properties:[:])).write(to:url)
        let native=MemoryImageTransitionView(frame:NSRect(x:0,y:0,width:640,height:400))
        let window=NSWindow(contentRect:native.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=native
        defer {native.stop();window.close()}
        let loaded=expectation(description:"Cancelled same-URL decode resumes")
        native.image.onImageSize={_ in loaded.fulfill()}
        var acknowledgements=0;native.onSettled={_ in acknowledgements += 1}
        let destination=CGRect(x:0,y:0,width:640,height:400)
        native.update(id:"same",url:url,regions:[],destination:destination,source:nil,radius:14,reduced:true)
        native.stop()
        native.update(id:"same",url:url,regions:[],destination:destination,source:nil,radius:14,reduced:true)
        await fulfillment(of:[loaded],timeout:5)
        XCTAssertEqual(acknowledgements,2,"A no-op remount still tells the caller its exact geometry is ready")
    }

    @MainActor func testMountedStageKeepsOneImageAndRevealsChromeAfterForwardAndReverseGeometry()async throws {
        for reduced in [false,true] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:root)}
            let model=try AppModel(root:root),image=picture(),path="frames/transition.png"
            try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation))?.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent(path))
            let frame=MemoryFrame(timestamp:Date().addingTimeInterval(-60),appName:"Synthetic",bundleID:"test",title:"Transition",imagePath:path,text:"",regions:[])
            try model.store.save(frame);model.select(frame)
            var shown:[Bool]=[]
            let ready=expectation(description:"Detail chrome revealed \(reduced)");ready.expectedFulfillmentCount=2
            let host=NSHostingView(rootView:MemoryDetailStage(model:model,frame:frame,screen:CGSize(width:900,height:700),topInset:0,source:nil,onOpen:{model.inspectorOpen=true},onChromeChanged:{visible in shown.append(visible);if visible {ready.fulfill()}},reducedMotionOverride:reduced))
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=host;window.orderFront(nil)
            func find(_ view:NSView)->MemoryImageTransitionView? {if let result=view as? MemoryImageTransitionView {return result};return view.subviews.compactMap(find).first}
            host.layoutSubtreeIfNeeded()
            let native=try XCTUnwrap(find(host)),surface=native.image
            // Opening uses the same native surface; no new image decode/view is
            // required even if its fitted rectangle has the same aspect ratio.
            model.inspectorOpen=true
            let open=XCTNSPredicateExpectation(predicate:NSPredicate {_ ,_ in shown.last == true},object:nil)
            await fulfillment(of:[open],timeout:5)
            XCTAssertTrue(native.image === surface);XCTAssertNil(model.player)
            let detailRect=native.image.frame
            model.inspectorOpen=false
            let closed=XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in shown.last == false && native.flight == nil},object:nil)
            await fulfillment(of:[closed],timeout:5)
            XCTAssertNotEqual(native.image.frame,detailRect)
            model.inspectorOpen=true
            await fulfillment(of:[ready],timeout:5)
            XCTAssertTrue(native.image === surface);XCTAssertEqual(native.image.cornerRadius,14)
            native.stop();window.close();model.prepareToQuit();await model.shutDownRecording();await model.storageOptimizer.stop()
        }
    }
}
