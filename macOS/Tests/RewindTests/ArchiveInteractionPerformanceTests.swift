import XCTest
import SwiftUI
import SceneKit
@testable import Rewind

private final class ArchiveRenderIntervals:NSObject,SCNSceneRendererDelegate,@unchecked Sendable {
    private let lock=NSLock()
    private var previous:Double?,values:[Double]=[]
    func renderer(_ renderer:SCNSceneRenderer,didRenderScene scene:SCNScene,atTime time:TimeInterval) {
        lock.lock();defer {lock.unlock()}
        if let previous,values.count < 4096 {values.append((time-previous)*1000)}
        previous=time
    }
    func reset() {lock.lock();previous=nil;values=[];lock.unlock()}
    func samples()->[Double] {lock.lock();defer {lock.unlock()};return values}
}

final class ArchiveInteractionPerformanceTests:XCTestCase {
    /// Full SwiftUI page and live Metal-backed SCNView, with synthetic pixels,
    /// real page reads and image completions. Events target this view directly;
    /// they never post global input or capture the user's desktop.
    @MainActor func testContinuousNativeWheelAndDragBenchmark()async throws {
        guard ProcessInfo.processInfo.environment["RECALL_ARCHIVE_INTERACTION_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in native synthetic interaction benchmark")
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("archive-interaction-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root),day=Calendar.current.startOfDay(for:Date())
        let image=NSImage(size:NSSize(width:1024,height:640),flipped:false) { rect in
            NSColor(red:0.11,green:0.17,blue:0.29,alpha:1).setFill();rect.fill()
            for row in 0..<12 {
                ("Synthetic archive interaction · row \(row) · 81742" as NSString).draw(at:NSPoint(x:32,y:CGFloat(row)*48+24),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:22,weight:.medium),.foregroundColor:NSColor.white])
            }
            return true
        }
        let pixels=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
        let base=root.appendingPathComponent("frames/source.png");try ScreenArchive.saveSource(pixels,to:base)
        for lane in -2...2 {for row in 0..<600 {
            let path="frames/\(lane)-\(row).png"
            try FileManager.default.linkItem(at:base,to:root.appendingPathComponent(path))
            try store.save(MemoryFrame(id:"\(lane)-\(row)",timestamp:day.addingTimeInterval(Double(lane)*86400+72000-Double(row)*60),appName:"Fixture",bundleID:"test",title:"Day \(lane), row \(row)",imagePath:path,text:"Synthetic 81742",regions:[]))
        }}
        let model=try AppModel(root:root,maintenanceOnly:true)
        model.settings.glassArchiveEnabled=true;model.onboardingOpen=false;model.archiveDay=day;model.reload()
        let host=NSHostingView(rootView:RootView(model:model).frame(width:1440,height:900))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1440,height:900),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host
        defer {window.orderOut(nil);model.interfaceVisibilityChanged(false);model.prepareToQuit()}
        model.interfaceVisibilityChanged(true);model.requestArchiveWindow(at:300)
        await model.waitForPendingLoads();window.orderFront(nil);host.layoutSubtreeIfNeeded()
        func archiveView(_ view:NSView)->ArchiveSceneView? {
            if let archive=view as? ArchiveSceneView {return archive}
            return view.subviews.lazy.compactMap {archiveView($0)}.first
        }
        // Warmup is deliberate benchmark pacing, never a semantic test wait.
        try await Task.sleep(for:.seconds(1))
        let view=try XCTUnwrap(archiveView(host)),scene=try XCTUnwrap(view.archive),render=ArchiveRenderIntervals()
        scene.scroll(by:(300-scene.scrollOffset)/0.42,precise:false)
        await model.waitForPendingLoads()
        try await Task.sleep(for:.seconds(1))
        view.delegate=render
        defer {view.delegate=nil;scene.onWorkMeasured=nil;view.cancelPendingInteraction();scene.stopMotion()}
        var stages:[String:[Double]]=[:]
        scene.onWorkMeasured={ stage,duration in
            let value=duration.components
            stages[stage,default:[]].append(Double(value.seconds)*1000+Double(value.attoseconds)/1e15)
        }
        func summary(_ label:String,_ samples:[Double]) {
            let values=samples.sorted();guard !values.isEmpty else {return}
            print(String(format:"ARCHIVE_NATIVE_INTERACTION %@ count=%d median=%.3fms p95=%.3fms max=%.3fms over33=%d",label,values.count,values[values.count/2],values[Int(Double(values.count-1)*0.95)],values.last!,values.filter {$0 > 33.34}.count))
        }
        for phase in ["wheel","drag"] {
            stages=[:];render.reset()
            var inputs:[Double]=[]
            let clock=ContinuousClock(),start=clock.now,startRow=scene.scrollOffset
            var readiness:[Double]=[]
            for sample in 0..<480 {
                let deadline=start.advanced(by:.seconds(Double(sample)/120))
                try await clock.sleep(until:deadline)
                let began=ContinuousClock.now
                if phase == "wheel" {
                    let event=try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:sample < 240 ? -22:22,wheel2:0,wheel3:0))
                    view.scrollWheel(with:try XCTUnwrap(NSEvent(cgEvent:event)))
                } else {
                    let step=sample % 60,direction=sample < 240 ? 1.0:-1.0
                    let origin:CGFloat=sample < 240 ? 160:640
                    func event(_ type:NSEvent.EventType,_ y:CGFloat)->NSEvent {
                        NSEvent.mouseEvent(with:type,location:NSPoint(x:700,y:y),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:0)!
                    }
                    if step == 0 {view.mouseDown(with:event(.leftMouseDown,origin))}
                    view.mouseDragged(with:event(.leftMouseDragged,origin+CGFloat(direction)*CGFloat(step+1)*8))
                    if step == 59 {view.mouseUp(with:event(.leftMouseUp,origin+CGFloat(direction)*480))}
                }
                let elapsed=began.duration(to:.now).components
                inputs.append(Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15)
                if sample % 120 == 0 {
                    let visible=scene.viewportRecords(in:view).visible
                    let ready=visible.filter {scene.scene.rootNode.childNode(withName:$0,recursively:true)?.childNode(withName:"artwork",recursively:false)?.isHidden == false}.count
                    readiness.append(Double(ready)/Double(max(1,visible.count)))
                }
            }
            summary(phase+" input",inputs)
            summary(phase+" render-interval",render.samples())
            for stage in stages.keys.sorted() {summary(phase+" "+stage,stages[stage]!)}
            let visible=scene.viewportRecords(in:view).visible
            let ready=visible.filter {scene.scene.rootNode.childNode(withName:$0,recursively:true)?.childNode(withName:"artwork",recursively:false)?.isHidden == false}.count
            print("ARCHIVE_NATIVE_INTERACTION \(phase) start=\(startRow) elapsed=\(start.duration(to:.now)) visible=\(visible.count) ready=\(ready) row=\(scene.scrollOffset) requests=\(model.archiveWindowRequestCount) textures=\(scene.textureUpdateCount) nodes=\(scene.residentNodeCount)")
            print("ARCHIVE_NATIVE_INTERACTION \(phase) ready-fractions=\(readiness)")
            XCTAssertLessThanOrEqual(scene.residentNodeCount,262)
            XCTAssertGreaterThan(render.samples().count,20,"Exercise the actual renderer, not only scene mutations")
            let stopped=ContinuousClock.now
            var finalVisible=0,finalReady=0
            repeat {
                view.refreshViewport(force:true)
                let visible=scene.viewportRecords(in:view).visible
                finalVisible=visible.count
                finalReady=visible.filter {scene.scene.rootNode.childNode(withName:$0,recursively:true)?.childNode(withName:"artwork",recursively:false)?.isHidden == false}.count
                if !scene.isAnimating,finalVisible > 0,finalReady == finalVisible {break}
                try await Task.sleep(for:.milliseconds(50))
            } while stopped.duration(to:.now) < .seconds(10)
            print("ARCHIVE_NATIVE_INTERACTION \(phase) stopped-ready=\(finalReady)/\(finalVisible) settled-in=\(stopped.duration(to:.now))")
            XCTAssertEqual(finalReady,finalVisible,"Stopping must fill every real screenshot in the final viewport")
        }
        await model.waitForPendingLoads();await scene.waitForFooters()
        XCTAssertGreaterThan(model.archiveWindowRequestCount,2)
        XCTAssertGreaterThan(scene.textureUpdateCount,20)
    }
}
