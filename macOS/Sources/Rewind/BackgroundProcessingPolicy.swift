import Foundation

/// Saved media can finish later; it must not monopolize a laptop while the
/// user works elsewhere. Pace successful jobs as well as failed retries.
enum BackgroundProcessingPolicy {
    static func recoveryInterval(after work:TimeInterval,
                                 pending:Int = 0,
                                 latencySensitive:Bool = false,
                                 thermal:ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
                                 lowPower:Bool = ProcessInfo.processInfo.isLowPowerModeEnabled)->TimeInterval {
        let multiplier:Double,minimum:Double,maximum:Double
        switch thermal {
        case .critical: (multiplier,minimum,maximum) = (4,5,60)
        case .serious: (multiplier,minimum,maximum) = (2,2,30)
        case .fair: (multiplier,minimum,maximum) = (latencySensitive || pending >= 32) && !lowPower ? (0.5,0.5,5):(1,0.5,10)
        default: (multiplier,minimum,maximum) = lowPower ? (1,0.5,10):(latencySensitive || pending >= 32) ? (0.05,0.15,0.5):(0.5,0.15,5)
        }
        return min(maximum,max(minimum,max(0,work)*multiplier))
    }
}
