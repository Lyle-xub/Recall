import XCTest
import AVKit
import CoreImage
@testable import Rewind

final class RecordingPresentationTests:XCTestCase {
    private func fixture()async throws->(URL,MemoryFrame) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try MemoryStore(root:root),start=Date().addingTimeInterval(-86400),path="recordings/first-frame.mp4"
        let sink=try LightweightVideoSink(url:root.appendingPathComponent(path),width:320,height:180,startedAt:start,hostStart:.zero,nativeArchive:true)
        sink.queue.sync {
            for second in 0..<12 {
                let color:CIColor=second < 4 ? .red:second < 8 ? .green:.blue
                let time=CMTime(seconds:Double(second),preferredTimescale:600)
                XCTAssertNotNil(sink.consume(CIImage(color:color).cropped(to:CGRect(x:0,y:0,width:320,height:180)),at:time,force:true))
            }
        }
        try await sink.finish(at:start.addingTimeInterval(12))
        let session=RecordingSession(startedAt:start,endedAt:start.addingTimeInterval(12),videoPath:path,appName:"Synthetic",hasAudio:false)
        try store.saveSession(session)
        let frame=MemoryFrame(timestamp:start.addingTimeInterval(5),appName:"Synthetic",bundleID:"test",title:"Green at five seconds",imagePath:"frames/poster.png",text:"",regions:[],sessionID:session.id)
        try store.save(frame)
        return (root,frame)
    }

    @MainActor func testColdAndWarmNativeFirstFrameKeepsPosterUntilExactSeekIsDisplayable()async throws {
        let (root,frame)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(root:root),native=RoundedRecordingPlayer(frame:NSRect(x:0,y:0,width:700,height:500))
        let window=NSWindow(contentRect:native.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=native;window.orderFront(nil)
        native.reducedMotion=true
        defer {native.setPlayer(nil);window.close()}
        model.select(frame);model.inspectorOpen=true
        var previous:AVPlayer?
        for pass in 0..<2 {
            model.openVideo();await model.waitForVideoLoad()
            let player=try XCTUnwrap(model.player);player.volume=0
            let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            player.currentItem?.add(output)
            XCTAssertFalse(model.videoReady);XCTAssertEqual(player.rate,0)
            XCTAssertEqual(player.currentTime().seconds,5,accuracy:0.002,"Seek must not fall back to the first keyframe")
            if let previous {XCTAssertEqual(previous.rate,0);model.videoDidBecomeReady(previous);XCTAssertFalse(model.videoReady)}
            let displayed=expectation(description:"Native first frame pass \(pass)")
            native.onReady={candidate in
                XCTAssertTrue(candidate === player)
                XCTAssertTrue(native.video.isReadyForDisplay)
                XCTAssertTrue(native.firstFrameVisible)
                XCTAssertEqual(candidate.currentTime().seconds,5,accuracy:0.002)
                XCTAssertEqual(native.video.frame.width/native.video.frame.height,320.0/180,accuracy:0.001)
                if let pixel=output.copyPixelBuffer(forItemTime:CMTime(seconds:5,preferredTimescale:600),itemTimeForDisplay:nil) {
                    CVPixelBufferLockBaseAddress(pixel,.readOnly)
                    let bytes=CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to:UInt8.self)
                    let index=CVPixelBufferGetBytesPerRow(pixel)*(CVPixelBufferGetHeight(pixel)/2)+(CVPixelBufferGetWidth(pixel)/2)*4
                    XCTAssertGreaterThan(bytes[index+1],200,"The native decoder's first target frame must be green, not the red zero-second frame")
                    XCTAssertLessThan(bytes[index+2],50)
                    CVPixelBufferUnlockBaseAddress(pixel,.readOnly)
                } else {XCTFail("The ready native player must expose the sought video frame")}
                model.videoDidBecomeReady(candidate);displayed.fulfill()
            }
            native.onFailure={_,message in XCTFail(message);displayed.fulfill()}
            native.setPlayer(player)
            XCTAssertFalse(native.firstFrameVisible,"The poster is not replaced at assignment")
            XCTAssertEqual(native.video.alphaValue,0)
            await fulfillment(of:[displayed],timeout:15)
            XCTAssertTrue(model.videoReady)
            let generator=AVAssetImageGenerator(asset:try XCTUnwrap(player.currentItem?.asset))
            generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
            let image=try await generator.image(at:CMTime(seconds:5,preferredTimescale:600)).image
            let pixels=NSBitmapImageRep(cgImage:image),color=try XCTUnwrap(pixels.colorAt(x:160,y:90)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(color.greenComponent,0.8);XCTAssertLessThan(color.redComponent,0.2)
            previous=player;model.stopVideo();native.setPlayer(nil)
            XCTAssertFalse(model.videoReady);XCTAssertFalse(native.firstFrameVisible);XCTAssertNil(native.video.player)
            print("PLAYBACK_PRESENTATION pass=\(pass) seek=5 nativeReady=true fitted=320:180 posterUntilReady=true")
        }
        model.prepareToQuit();await model.shutDownRecording();await model.storageOptimizer.stop()
    }

    @MainActor func testNativeReplacementDoesNotRevealOldItemAndFailureKeepsPoster()async throws {
        let (root,frame)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(root:root),native=RoundedRecordingPlayer(frame:NSRect(x:0,y:0,width:640,height:400))
        let window=NSWindow(contentRect:native.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=native;window.orderFront(nil);native.reducedMotion=true
        defer {native.setPlayer(nil);window.close()}
        model.select(frame);model.inspectorOpen=true;model.openVideo();await model.waitForVideoLoad()
        let old=try XCTUnwrap(model.player),first=expectation(description:"Old item is displayable")
        native.onReady={_ in first.fulfill()};native.setPlayer(old)
        await fulfillment(of:[first],timeout:15)
        XCTAssertTrue(native.firstFrameVisible)
        model.openVideo();await model.waitForVideoLoad()
        let replacement=try XCTUnwrap(model.player),replaced=expectation(description:"Only the replacement is revealed")
        var callbacks=0
        native.onReady={candidate in
            callbacks += 1;XCTAssertTrue(candidate === replacement)
            XCTAssertEqual(candidate.currentTime().seconds,5,accuracy:0.002);replaced.fulfill()
        }
        native.setPlayer(replacement)
        XCTAssertFalse(native.firstFrameVisible);XCTAssertEqual(native.video.alphaValue,0)
        await fulfillment(of:[replaced],timeout:15)
        XCTAssertEqual(callbacks,1);XCTAssertEqual(old.rate,0)
        let failed=expectation(description:"Invalid media reports failure without revealing black video")
        let bad=AVPlayer(url:root.appendingPathComponent("missing.mp4"))
        native.onReady={_ in XCTFail("A missing movie cannot reveal a native video surface")}
        native.onFailure={candidate,_ in
            XCTAssertTrue(candidate === bad);XCTAssertFalse(native.firstFrameVisible)
            XCTAssertEqual(native.video.alphaValue,0);failed.fulfill();native.setPlayer(nil)
        }
        native.setPlayer(bad)
        await fulfillment(of:[failed],timeout:15)
        XCTAssertNil(native.video.player)
        model.prepareToQuit();await model.shutDownRecording();await model.storageOptimizer.stop()
    }

    @MainActor func testCancelledAndReplacedLoadsCannotStartAudioOrRestoreOldPlayer()async throws {
        let (root,frame)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(root:root)
        model.select(frame);model.inspectorOpen=true
        model.openVideo();model.back();await model.waitForVideoLoad()
        XCTAssertNil(model.player);XCTAssertFalse(model.videoReady)
        model.select(frame);model.inspectorOpen=true
        model.openVideo();await model.waitForVideoLoad()
        let old=try XCTUnwrap(model.player)
        model.openVideo();model.openVideo();await model.waitForVideoLoad()
        let newest=try XCTUnwrap(model.player)
        XCTAssertFalse(old === newest);XCTAssertEqual(old.rate,0);XCTAssertEqual(newest.rate,0)
        model.videoDidBecomeReady(old);XCTAssertFalse(model.videoReady)
        model.stopVideo();model.meetingView.toggle();model.videoDidBecomeReady(newest)
        XCTAssertNil(model.player);XCTAssertFalse(model.videoReady);XCTAssertEqual(newest.rate,0)
        var missing=frame;missing.id="missing-video";missing.sessionID="missing-session"
        model.select(missing);model.inspectorOpen=true;model.openVideo();await model.waitForVideoLoad()
        XCTAssertNil(model.player)
        model.prepareToQuit();await model.shutDownRecording();await model.storageOptimizer.stop()
    }
}
