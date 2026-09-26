import Foundation
import simd

/// A broad shoulder plus a narrow crest gives the rack a mountain silhouette.
/// Moving the crest translates the whole height field, not just the hit card.
enum ArchiveRidgeProfile {
    static func height(lane:Double,depth:Double,crest:Double,across:Double = 0)->Double {
        let x = lane-across
        let d = depth-crest-abs(lane-across)*0.42
        let shoulder = 2.1*exp(-x*x/2)*exp(-d*d/(2*5.3*5.3))
        let summit = 1.9*exp(-x*x/0.48)*exp(-d*d/(2*0.85*0.85))
        return -1.35+(lane < 0 ? 0.4:lane > 0 ? -0.35:0)+shoulder+summit
    }
}

/// Exact critically damped spring integration. Keeping velocity on retarget
/// makes both pointer waves and interrupted extraction continuous.
struct ArchiveMotionSpring {
    var value:Double
    var velocity:Double = 0
    mutating func step(to target:Double,frequency:Double,dt:Double) {
        let displacement = value-target
        let c = velocity+frequency*displacement
        let decay = exp(-frequency*dt)
        value = target+(displacement+c*dt)*decay
        velocity = (velocity-frequency*c*dt)*decay
    }
    func settled(at target:Double)->Bool { abs(value-target) < 0.0004 && abs(velocity) < 0.003 }
}

enum ArchiveExtractionPath {
    static func smooth(_ value:Float)->Float { let t = max(0,min(1,value));return t*t*(3-2*t) }
    static func position(from origin:SIMD3<Float>,to destination:SIMD3<Float>,progress:Float)->SIMD3<Float> {
        let p = max(0,min(1,progress))
        let clearance = origin+SIMD3<Float>(0,0.85,3.4)
        if p <= 0.34 { return origin+(clearance-origin)*smooth(p/0.34) }
        let t = smooth((p-0.34)/0.66),u = 1-t
        let c1 = clearance+SIMD3<Float>(0,0.15,2)
        let c2 = destination+SIMD3<Float>(0,0.8,-1.2)
        return u*u*u*clearance+3*u*u*t*c1+3*u*t*t*c2+t*t*t*destination
    }
    static func rotationProgress(_ progress:Float)->Float { smooth((progress-0.30)/0.65) }
}
