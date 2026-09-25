import XCTest
import simd
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
}
