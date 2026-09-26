import XCTest
import AppKit
import SceneKit
import Metal
@testable import Rewind

/// Opt-in, warmed rendering measurements using a read-only recording library.
/// GPU/CPU costs exclude window compositing and are not an on-screen FPS claim.
final class ArchivePerformanceTests:XCTestCase {
    @MainActor func testPointerSweepBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["RECALL_ARCHIVE_BENCHMARK"] == "1",
              let path = ProcessInfo.processInfo.environment["RECALL_ARCHIVE_SOURCE_ROOT"] else {
            throw XCTSkip("Set RECALL_ARCHIVE_BENCHMARK=1 and RECALL_ARCHIVE_SOURCE_ROOT")
        }
        let root = URL(fileURLWithPath:path),reader = try MemoryStore(root:root,readOnly:true)
        let day = try XCTUnwrap(reader.frames(demo:false,limit:1).first?.timestamp)
        let frames = try reader.archiveFrames(around:day)
        let images = Dictionary(uniqueKeysWithValues:try frames.map { frame in
            let pixels = try XCTUnwrap(StoredImage.load(root.appendingPathComponent(frame.imagePath),maxPixels:560))
            return (frame.imagePath,NSImage(cgImage:pixels,size:NSSize(width:pixels.width,height:pixels.height)))
        })
        let size = CGSize(width:1512,height:982),archive = ArchiveGlassScene()
        archive.update(frames:frames,images:images,appearance:.warmDay,selected:nil,size:size,reduced:false,day:day)
        defer { archive.stopMotion() }
        let view = ArchiveSceneView(frame:CGRect(origin:.zero,size:size))
        view.scene = archive.scene;view.pointOfView = archive.cameraNode;view.archive = archive
        view.antialiasingMode = .multisampling2X
        let window = NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = view
        defer { window.orderOut(nil) }
        view.onPointer = { near,far,id in archive.pointer(rayNear:near,rayFar:far,recordID:id) }
        view.onHover = { archive.hover($0) }
        _ = view.snapshot()
        var input:[Double] = [],motion:[Double] = [],visibility:[Double] = []
        for index in 0..<300 {
            let point = CGPoint(x:100+Double(index % 100)*13,y:300+Double(index % 9)*35)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with:.mouseMoved,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0))
            var start = CACurrentMediaTime();view.mouseMoved(with:event);input.append((CACurrentMediaTime()-start)*1000)
            start = CACurrentMediaTime();archive.advance(dt:1/60);motion.append((CACurrentMediaTime()-start)*1000)
            if index % 6 == 0 {
                start = CACurrentMediaTime();_ = archive.viewportRecords(in:view);visibility.append((CACurrentMediaTime()-start)*1000)
            }
        }
        var nativePicking:[Double] = [],cachedPicking:[Double] = []
        for index in 0..<120 {
            let point = CGPoint(x:100+Double(index % 100)*13,y:300+Double(index % 9)*35)
            var start = CACurrentMediaTime()
            _ = view.hitTest(point,options:[.searchMode:SCNHitTestSearchMode.closest.rawValue,.categoryBitMask:1])
            nativePicking.append((CACurrentMediaTime()-start)*1000)
            start = CACurrentMediaTime()
            let (near,far) = view.pointerRay(at:point)
            _ = archive.record(at:near,toward:far)
            cachedPicking.append((CACurrentMediaTime()-start)*1000)
        }
        // The offscreen GPU pass must not compete with another renderer for
        // this same scene; native input has already been measured above.
        view.scene = nil
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()),queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = SCNRenderer(device:device,options:nil)
        renderer.scene = archive.scene;renderer.pointOfView = archive.cameraNode
        let texture = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:3024,height:1964,mipmapped:false)
        texture.usage = [.renderTarget,.shaderRead];texture.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor:texture))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float_stencil8,width:3024,height:1964,mipmapped:false)
        depth.usage = .renderTarget;depth.storageMode = .private
        let depthTarget = try XCTUnwrap(device.makeTexture(descriptor:depth))
        pass.depthAttachment.texture = depthTarget;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .dontCare
        pass.stencilAttachment.texture = depthTarget;pass.stencilAttachment.loadAction = .clear;pass.stencilAttachment.storeAction = .dontCare
        var gpu:[Double] = [],render:[Double] = []
        for index in 0..<140 {
            archive.pointer(at:CGPoint(x:0.25+0.5*Double(index % 70)/70,y:0.55))
            archive.advance(dt:1/60)
            let buffer = try XCTUnwrap(queue.makeCommandBuffer()),start = CACurrentMediaTime()
            renderer.render(atTime:Double(index)/60,viewport:CGRect(x:0,y:0,width:3024,height:1964),commandBuffer:buffer,passDescriptor:pass)
            let submitted = CACurrentMediaTime()
            buffer.commit();buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            if index >= 20 { gpu.append((buffer.gpuEndTime-buffer.gpuStartTime)*1000);render.append((submitted-start)*1000) }
        }
        for (label,samples) in [("input",input),("motion",motion),("viewport",visibility),("native-picking",nativePicking),("cached-picking",cachedPicking),("render-submit",render),("GPU",gpu)] {
            let sorted = samples.sorted()
            print(String(format:"ARCHIVE_SWEEP %@: median %.3f ms; p95 %.3f ms; max %.3f ms (%d records, 3024x1964)",label,sorted[sorted.count/2],sorted[Int(Double(sorted.count-1)*0.95)],sorted.last!,frames.count))
        }
        guard ProcessInfo.processInfo.environment["RECALL_ARCHIVE_LIVE_BENCHMARK"] == "1" else { return }
        renderer.scene = nil
        let recorder = ArchiveRenderIntervals()
        view.scene = archive.scene;view.delegate = recorder;view.preferredFramesPerSecond = 60
        archive.attachAnimation(to:view)
        archive.onPresentationChanged = { [weak view] in view?.needsDisplay = true }
        defer { view.delegate = nil;archive.onPresentationChanged = nil;view.cancelPendingInteraction() }
        window.level = .statusBar;window.orderFront(nil)
        try await Task.sleep(for:.milliseconds(500))
        recorder.reset()
        let start = CACurrentMediaTime()
        while CACurrentMediaTime()-start < 3 {
            let elapsed = CACurrentMediaTime()-start
            let point = CGPoint(x:size.width*(0.5+0.35*sin(elapsed*5)),y:size.height*(0.45+0.18*cos(elapsed*3)))
            let event = try XCTUnwrap(NSEvent.mouseEvent(with:.mouseMoved,location:point,modifierFlags:[],timestamp:elapsed,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0))
            view.mouseMoved(with:event)
            try await Task.sleep(for:.milliseconds(4))
        }
        let intervals = recorder.intervals.sorted()
        XCTAssertGreaterThan(intervals.count,20,"The display-linked archive must keep rendering while the pointer moves")
        if !intervals.isEmpty {
            print(String(format:"ARCHIVE_LIVE_RENDER: median %.2f ms; p95 %.2f ms; %d/%d intervals over 25 ms (SceneKit callbacks; not full-app presentation FPS)",intervals[intervals.count/2],intervals[Int(Double(intervals.count-1)*0.95)],intervals.filter { $0 > 25 }.count,intervals.count))
        }
    }
}

private final class ArchiveRenderIntervals:NSObject,SCNSceneRendererDelegate,@unchecked Sendable {
    private let lock = NSLock()
    private var timestamps:[Double] = []
    func renderer(_ renderer:SCNSceneRenderer,didRenderScene scene:SCNScene,atTime time:TimeInterval) {
        lock.withLock { timestamps.append(CACurrentMediaTime()) }
    }
    func reset() { lock.withLock { timestamps.removeAll() } }
    var intervals:[Double] {
        lock.withLock { zip(timestamps,timestamps.dropFirst()).map { ($0.1-$0.0)*1000 } }
    }
}
