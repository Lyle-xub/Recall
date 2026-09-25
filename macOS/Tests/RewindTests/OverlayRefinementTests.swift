import XCTest
import CoreGraphics
@testable import Rewind

final class OverlayRefinementTests:XCTestCase {
    func testColoredGlyphSurvivesWhiteTileAndTransparentPadding() throws {
        let icon = try draw { context in
            context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:4,y:4,width:56,height:56))
            context.setFillColor(CGColor(red:0.15,green:0.35,blue:0.90,alpha:1)); context.fill(CGRect(x:20,y:16,width:24,height:32))
        }
        let color = try XCTUnwrap(IconColorSampler.sample(icon))
        XCTAssertGreaterThan(color.blue,color.red*2)
        XCTAssertGreaterThan(color.blue,color.green*1.5)
        XCTAssertFalse(color.isNeutral)
    }
    func testMonochromeIconsStayNeutralAndEmptyIconsHaveNoColor() throws {
        let icon = try draw { context in
            context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:64,height:64))
            context.setFillColor(CGColor(gray:0.1,alpha:1)); context.fill(CGRect(x:18,y:18,width:28,height:28))
        }
        XCTAssertTrue(try XCTUnwrap(IconColorSampler.sample(icon)).isNeutral)
        XCTAssertNil(IconColorSampler.sample(try draw { _ in }))
    }
    func testDominantColorOutweighsSmallAccent() throws {
        let icon = try draw { context in
            context.setFillColor(CGColor(red:0.1,green:0.75,blue:0.25,alpha:1)); context.fill(CGRect(x:0,y:0,width:64,height:64))
            context.setFillColor(CGColor(red:0.95,green:0.1,blue:0.1,alpha:1)); context.fill(CGRect(x:22,y:22,width:18,height:18))
        }
        let color = try XCTUnwrap(IconColorSampler.sample(icon))
        XCTAssertGreaterThan(color.green,color.red*2); XCTAssertGreaterThan(color.green,color.blue*2)
    }
    func testOverlayCaptureUsesUnderlyingApplicationWithoutSkippingPrivateWindows() {
        let recall = CaptureApplication(pid:10,name:"Recall",bundleID:"studio.rewind.replica",title:"Timeline")
        let browser = CaptureApplication(pid:11,name:"Browser",bundleID:"test.browser",title:"Page")
        let privateApp = CaptureApplication(pid:12,name:"Private",bundleID:"test.private",title:"Private window")
        XCTAssertEqual(CaptureForeground.choose(frontmost:recall,visibleWindows:[recall,browser],ownPID:10),browser)
        XCTAssertEqual(CaptureForeground.choose(frontmost:browser,visibleWindows:[recall],ownPID:10),browser)
        let target = CaptureForeground.choose(frontmost:recall,visibleWindows:[privateApp,browser],ownPID:10)
        XCTAssertEqual(target,privateApp)
        var settings = AppSettings(); settings.excludedApps = [privateApp.bundleID]
        XCTAssertEqual(AppUsageIdentity.resolved(name:target.name,bundleID:target.bundleID,ownApp:false,settings:settings).kind,.excluded)
        XCTAssertEqual(CaptureForeground.choose(frontmost:recall,visibleWindows:[recall],ownPID:10),.desktop)
    }
    private func draw(_ drawing:(CGContext)->Void) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        drawing(context); return try XCTUnwrap(context.makeImage())
    }
}
