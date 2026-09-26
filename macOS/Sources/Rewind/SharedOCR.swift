import Foundation
import CryptoKit

/// Coordinates and text are immutable shared content. Per-frame region IDs
/// remain in the small metadata row so existing selections and exports round-trip.
struct SharedOCR:Codable {
    var regions:[TextRegion]
    var meetingRegions:[TextRegion]
    init(regions:[TextRegion],meetingRegions:[TextRegion]) {self.regions=regions;self.meetingRegions=meetingRegions}
    init(_ frame:MemoryFrame) {
        regions = frame.regions;meetingRegions = frame.meetingRegions
        for i in regions.indices { regions[i].id = String(i) }
        for i in meetingRegions.indices { meetingRegions[i].id = String(i) }
    }
    static func key(text:String,data:Data)->String {
        var hash = SHA256();hash.update(data:Data(text.utf8));hash.update(data:Data([0]));hash.update(data:data)
        return hash.finalize().map {String(format:"%02x",$0)}.joined()
    }
}
