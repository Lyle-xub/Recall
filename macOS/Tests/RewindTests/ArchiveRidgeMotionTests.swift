import XCTest
import simd
import AppKit
import SceneKit
@testable import Rewind

final class ArchiveRidgeMotionTests: XCTestCase {
    func testRidgeHasContinuousShouldersAndMovingCrest() {
        let summit = ArchiveRidgeProfile.height(lane:0,depth:0,crest:0)
        let shoulder = ArchiveRidgeProfile.height(lane:1,depth:0,crest:0)
        let edge = ArchiveRidgeProfile.height(lane:2,depth:0,crest:0)
        XCTAssertGreaterThan(summit,shoulder)
        XCTAssertGreaterThan(shoulder,edge)
        XCTAssertGreaterThan(ArchiveRidgeProfile.height(lane:0,depth:4,crest:4),ArchiveRidgeProfile.height(lane:0,depth:4,crest:0))
        for lane in -2...2 {
            for depth in -6...20 {
                let a = ArchiveRidgeProfile.height(lane:Double(lane),depth:Double(depth),crest:1)
                let b = ArchiveRidgeProfile.height(lane:Double(lane),depth:Double(depth),crest:1.001)
                XCTAssertLessThan(abs(a-b),0.003,"Pointer motion must not jump between cards")
            }
        }
    }
    func testInterruptedSpringPreservesVelocityAndSettles() {
        var motion = ArchiveMotionSpring(value:0)
        for _ in 0..<20 { motion.step(to:1,frequency:6.5,dt:1/60) }
        let before = motion
        motion.step(to:0,frequency:6.5,dt:0)
        XCTAssertEqual(motion.value,before.value,accuracy:1e-12)
        XCTAssertEqual(motion.velocity,before.velocity,accuracy:1e-12)
        for _ in 0..<180 { motion.step(to:0,frequency:6.5,dt:1/60) }
        XCTAssertTrue(motion.settled(at:0))
        for _ in 0..<180 { motion.step(to:1,frequency:6.5,dt:1/60) }
        XCTAssertTrue(motion.settled(at:1))
    }
    func testExtractionClearsRackBeforeTurningAndHasNoPathJump() {
        let origin = SIMD3<Float>(0,2,-5),destination = SIMD3<Float>(-5,10,12)
        XCTAssertEqual(ArchiveExtractionPath.position(from:origin,to:destination,progress:0),origin)
        XCTAssertEqual(ArchiveExtractionPath.position(from:origin,to:destination,progress:1),destination)
        XCTAssertEqual(ArchiveExtractionPath.rotationProgress(0.25),0)
        let lifted = ArchiveExtractionPath.position(from:origin,to:destination,progress:0.34)
        XCTAssertGreaterThan(lifted.y,origin.y+0.8)
        var previous = origin
        for i in 1...1000 {
            let point = ArchiveExtractionPath.position(from:origin,to:destination,progress:Float(i)/1000)
            XCTAssertLessThan(simd_distance(previous,point),0.07)
            previous = point
        }
    }
    @MainActor func testSummitFollowsCameraRayAcrossColumnsAndAfterScroll() {
        let scene = ArchiveGlassScene()
        scene.update(frames:[],images:[:],appearance:.warmDay,selected:nil,size:CGSize(width:1440,height:900),reduced:false)
        let rack = scene.scene.rootNode.childNode(withName:"racks",recursively:false)!
        for x:CGFloat in [-5.65,0,6.25] {
            scene.pointer(rayNear:SCNVector3(x,15,-1),rayFar:SCNVector3(x,-15,-1))
            for _ in 0..<180 { scene.advance(dt:1/60) }
            let summit = rack.childNodes.max { $0.position.y < $1.position.y }!
            XCTAssertEqual(summit.position.x,x,accuracy:0.01,"The tallest sheet must move to the pointer's column")
            XCTAssertEqual(summit.position.z,-1,accuracy:0.6)
        }
        scene.scroll(by:10,precise:false)
        scene.pointer(rayNear:SCNVector3(0,15,6),rayFar:SCNVector3(0,-15,6))
        for _ in 0..<180 { scene.advance(dt:1/60) }
        let summit = rack.childNodes.max { $0.position.y < $1.position.y }!
        XCTAssertEqual(summit.position.z,6,accuracy:0.6)
        for _ in 0..<180 { scene.advance(dt:1/60) }
        let writes = scene.positionUpdateCount
        for _ in 0..<60 { scene.advance(dt:1/60) }
        XCTAssertEqual(scene.positionUpdateCount,writes,"Settled sheets should not keep writing SceneKit transforms")
        scene.stopMotion()
    }
    @MainActor func testSceneTracksPointerWithoutKeyFocusAndKeepsTrackingAreaStable() {
        let view = ArchiveSceneView(frame:NSRect(x:0,y:0,width:900,height:600))
        view.updateTrackingAreas()
        let own = view.trackingAreas.filter { $0.options.contains(.activeAlways) && $0.options.contains(.mouseMoved) }
        XCTAssertEqual(own.count,1)
        view.updateTrackingAreas()
        XCTAssertTrue(view.trackingAreas.contains { $0 === own[0] })
        var received = 0
        view.onPointer = { _,_ in received += 1 }
        let event = NSEvent.mouseEvent(with:.mouseMoved,location:NSPoint(x:450,y:300),modifierFlags:[],timestamp:1,windowNumber:0,context:nil,eventNumber:0,clickCount:0,pressure:0)!
        view.mouseMoved(with:event)
        XCTAssertEqual(received,1)
    }

}
