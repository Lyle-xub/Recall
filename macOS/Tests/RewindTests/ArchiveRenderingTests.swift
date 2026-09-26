import XCTest
import AppKit
import SceneKit
@testable import Rewind

final class ArchiveRenderingTests:XCTestCase {
    @MainActor func testScreenshotKeepsDaylightPixelsAndSoftensOnlyNightImages() throws {
        let size = CGSize(width:800,height:500)
        let frame = MemoryFrame(timestamp:Date(),appName:"Brightness fixture",bundleID:"test",title:"",imagePath:"patches",text:"",regions:[])
        let context = try XCTUnwrap(CGContext(data:nil,width:320,height:200,bitsPerComponent:8,bytesPerRow:0,
            space:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed:1,green:1,blue:1,alpha:1));context.fill(CGRect(x:0,y:0,width:320,height:200))
        context.setFillColor(CGColor(srgbRed:0.5,green:0.5,blue:0.5,alpha:1));context.fill(CGRect(x:160,y:0,width:160,height:200))
        let source = NSImage(cgImage:try XCTUnwrap(context.makeImage()),size:NSSize(width:320,height:200))
        for appearance:OverlayAppearance in [.warmDay,.deepNight] {
            let archive = ArchiveGlassScene()
            archive.update(frames:[frame],images:[frame.imagePath:source],appearance:appearance,selected:frame.id,size:size,reduced:true)
            let renderer = SCNRenderer(device:nil,options:nil)
            renderer.scene = archive.scene;renderer.pointOfView = archive.cameraNode
            let image = renderer.snapshot(atTime:0,with:size,antialiasingMode:.multisampling2X)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation)))
            let (_,art,rect) = try XCTUnwrap(archive.selectionSurface())
            for (fraction,expected): (CGFloat,CGFloat) in [(0.25,1),(0.75,0.5)] {
                let local = SCNVector3(rect.minX+rect.width*fraction,rect.midY,0)
                let point = renderer.projectPoint(art.convertPosition(local,to:nil))
                // colorAt labels components as calibrated RGB even for this
                // sRGB bitmap. Read its encoded samples without converting twice.
                XCTAssertEqual(bitmap.colorSpace,.sRGB)
                let color = try XCTUnwrap(bitmap.colorAt(x:Int(point.x),y:Int(size.height-point.y)))
                let target = appearance == .deepNight ? (expected == 1 ? 0.896:0.445):expected
                XCTAssertEqual(color.redComponent,target,accuracy:0.025,"Daylight stays faithful; night screenshots receive a restrained brightness reduction")
            }
            archive.stopMotion()
        }
    }

    @MainActor func testExtractionReusesMeshesAndOnlyUpgradesOneFooter() throws {
        var size = CGSize(width:1440,height:900)
        let frames = (0..<24).map { index in
            MemoryFrame(timestamp:Date().addingTimeInterval(Double(-index)*60),appName:"Rendering fixture",bundleID:"test",title:"",imagePath:"\(index)",text:"",regions:[])
        }
        let archive = ArchiveGlassScene()
        func update(_ selection:String?) {
            archive.update(frames:frames,images:[:],appearance:.warmDay,selected:selection,size:size,reduced:false)
        }
        update(nil)
        let card = try XCTUnwrap(archive.scene.rootNode.childNode(withName:frames[0].id,recursively:true))
        let bodyNode = try XCTUnwrap(card.childNode(withName:"glass",recursively:false))
        let body = try XCTUnwrap(bodyNode.geometry as? SCNBox)
        let art = try XCTUnwrap(card.childNode(withName:"artwork",recursively:false))
        let plane = try XCTUnwrap(art.geometry as? SCNPlane)
        let meshSize = CGSize(width:body.width,height:body.height)
        let artSize = CGSize(width:plane.width,height:plane.height)
        let builds = archive.informationTextureBuildCount
        update(frames[0].id)
        for _ in 0..<150 {
            archive.advance(dt:1/60)
            XCTAssertEqual(CGSize(width:body.width,height:body.height),meshSize,"Animated sheets must reuse GPU geometry")
            XCTAssertEqual(CGSize(width:plane.width,height:plane.height),artSize)
        }
        XCTAssertEqual(archive.informationTextureBuildCount,builds+1,"Only the opened card needs an expanded footer texture")
        XCTAssertTrue(bodyNode.geometry === body)
        XCTAssertGreaterThan(art.scale.x,1.5)
        XCTAssertNotNil(archive.selectionSurface(),"Scaled artwork must still support OCR projection")
        XCTAssertFalse(archive.cameraNode.camera!.wantsDepthOfField)
        let footer = try XCTUnwrap(card.childNode(withName:"information",recursively:false))
        let footerPlane = try XCTUnwrap(footer.geometry as? SCNPlane)
        let artLeft = art.position.x-plane.width*art.scale.x/2
        let footerLeft = footer.position.x-footerPlane.width*footer.scale.x/2
        XCTAssertEqual(artLeft,footerLeft,accuracy:0.0001)
        size = CGSize(width:800,height:600)
        update(frames[0].id)
        for _ in 0..<120 { archive.advance(dt:1/60) }
        let span = CGFloat(archive.cameraNode.camera!.orthographicScale)*2
        let position = archive.cameraNode.convertPosition(card.worldPosition,from:nil)
        XCTAssertEqual(position.y,ArchiveViewportLayout.extractionCenterY(in:size,verticalSpan:span),accuracy:0.001,"Resizing must reposition an already settled card above the timeline")
        update(nil)
        for _ in 0..<180 { archive.advance(dt:1/60) }
        XCTAssertNil(archive.selectionSurface())
        XCTAssertTrue(archive.cameraNode.camera!.wantsDepthOfField)
        archive.stopMotion()
    }

    @MainActor func testCoveredSceneStopsItsClockAndResumesExistingCards() throws {
        let archive = ArchiveGlassScene()
        archive.update(frames:[],images:[:],appearance:.warmDay,selected:nil,size:CGSize(width:1440,height:900),reduced:false)
        let rack = try XCTUnwrap(archive.scene.rootNode.childNode(withName:"racks",recursively:false))
        let card = try XCTUnwrap(rack.childNodes.first)
        let original = card.position
        archive.setActive(false)
        archive.pointer(at:CGPoint(x:0.9,y:0.8))
        for _ in 0..<30 { archive.advance(dt:1/60) }
        XCTAssertFalse(archive.isAnimating)
        XCTAssertEqual(card.position.x,original.x)
        XCTAssertEqual(card.position.y,original.y)
        archive.setActive(true)
        XCTAssertTrue(archive.isAnimating)
        for _ in 0..<240 { archive.advance(dt:1/60) }
        XCTAssertTrue(rack.childNodes.first === card)
        XCTAssertFalse(archive.isAnimating,"The resumed wave also stops once settled")
        archive.stopMotion()
    }
}
