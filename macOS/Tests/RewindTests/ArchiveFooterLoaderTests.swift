import XCTest
import AppKit
import SceneKit
@testable import Rewind

private actor ArchiveFooterGate {
    private var continuations:[String:CheckedContinuation<ArchivePreparedFooter?,Never>]=[:]
    private(set) var started:[String]=[]
    func prepare(_ request:ArchiveFooterRequest)async->ArchivePreparedFooter? {
        started.append(request.key)
        return await withCheckedContinuation {continuations[request.key]=$0}
    }
    func complete(_ key:String) {
        let material=SCNMaterial();material.name=key
        continuations.removeValue(forKey:key)?.resume(returning:ArchivePreparedFooter(material))
    }
}

final class ArchiveFooterLoaderTests:XCTestCase {
    private func request(_ id:String,_ key:String,row:Double = 0)->ArchiveFooterRequest {
        let frame=MemoryFrame(timestamp:Date(),appName:id,bundleID:"test",title:key,imagePath:id+".png",text:"",regions:[])
        return ArchiveFooterRequest(id:id,key:key,frame:frame,night:key.contains("night"),aspect:4.85,row:row)
    }
    @MainActor func testSelectedPriorityAndObsoleteNightStarResultCannotReplaceNewContent()async {
        let gate=ArchiveFooterGate(),loader=ArchiveFooterLoader(prepare:{await gate.prepare($0)})
        var applied:[String]=[]
        for id in ["a","b","c"] {loader.request(request(id,id,row:Double(applied.count))) {applied.append($0.material.name!)}}
        loader.prioritize(selected:"c",center:0)
        while await gate.started.count < 2 {await Task.yield()}
        let first=await gate.started
        XCTAssertEqual(Set(first),["a","c"])
        loader.request(request("a","a-night-star")) {applied.append($0.material.name!)}
        loader.retain(["a","c"])
        for key in first {await gate.complete(key)}
        while await gate.started.count < 3 {await Task.yield()}
        XCTAssertEqual(applied,["c"],"An older appearance/star revision cannot overwrite the queued replacement")
        await gate.complete("a-night-star");await loader.waitUntilIdle()
        XCTAssertEqual(applied,["c","a-night-star"])
        XCTAssertEqual(loader.maximumConcurrency,2)
        XCTAssertEqual(loader.pendingCount,0)
    }

    @MainActor func testStopDiscardsInFlightResultsAndResumeUsesFreshGeneration()async {
        let gate=ArchiveFooterGate(),loader=ArchiveFooterLoader(prepare:{await gate.prepare($0)})
        var applied=0
        loader.request(request("a","old")) {_ in applied += 1}
        while await gate.started.isEmpty {await Task.yield()}
        loader.stop();await gate.complete("old");await loader.waitUntilIdle()
        XCTAssertEqual(applied,0)
        loader.resume();loader.request(request("a","new")) {_ in applied += 1}
        while await gate.started.count < 2 {await Task.yield()}
        await gate.complete("new");await loader.waitUntilIdle()
        XCTAssertEqual(applied,1)
    }

    @MainActor func testEvictionBoundsQueueAndMaterialsStayIndependentAcrossCards()async throws {
        let loader=ArchiveFooterLoader(prepare:{request in
            let material=SCNMaterial();material.name=request.key;return ArchivePreparedFooter(material)
        })
        var applied=Set<String>()
        for index in 0..<262 {loader.request(request("\(index)","\(index)")) {_ in applied.insert("\(index)")}}
        XCTAssertLessThanOrEqual(loader.pendingCount,262)
        loader.retain(Set((0..<52).map(String.init)))
        await loader.waitUntilIdle()
        XCTAssertEqual(applied.count,52)
        XCTAssertLessThanOrEqual(loader.maximumConcurrency,2)

        let day=Calendar.current.startOfDay(for:Date()),scene=ArchiveGlassScene()
        defer {scene.setActive(false);scene.stopMotion()}
        let frames=(0..<2).map {index in MemoryFrame(timestamp:day.addingTimeInterval(Double(index)*60),appName:"Footer fixture",bundleID:"test",title:"Unique \(index)",imagePath:"\(index).png",text:"",regions:[])}
        let first=NSImage(size:NSSize(width:160,height:100)),second=NSImage(size:NSSize(width:160,height:100))
        scene.update(frames:frames,images:[frames[0].imagePath:first,frames[1].imagePath:second],appearance:.warmDay,selected:nil,size:CGSize(width:1440,height:900),reduced:true,day:day)
        await scene.waitForFooters()
        let a=try XCTUnwrap(scene.scene.rootNode.childNode(withName:frames[0].id,recursively:true))
        let b=try XCTUnwrap(scene.scene.rootNode.childNode(withName:frames[1].id,recursively:true))
        let aInfo=try XCTUnwrap(a.childNode(withName:"information",recursively:false)?.geometry?.firstMaterial)
        let bInfo=try XCTUnwrap(b.childNode(withName:"information",recursively:false)?.geometry?.firstMaterial)
        XCTAssertFalse(aInfo === bInfo,"Per-card title and star materials must never be shared")
        XCTAssertNotNil(aInfo.diffuse.contents);XCTAssertNotNil(bInfo.diffuse.contents)
        let aArt=try XCTUnwrap(a.childNode(withName:"artwork",recursively:false)?.geometry?.firstMaterial)
        let bArt=try XCTUnwrap(b.childNode(withName:"artwork",recursively:false)?.geometry?.firstMaterial)
        XCTAssertFalse(aArt === bArt)
        XCTAssertTrue(aArt.diffuse.contents as? NSImage === first)
        XCTAssertTrue(bArt.diffuse.contents as? NSImage === second)
        XCTAssertTrue(a.childNode(withName:"glass",recursively:false)?.geometry === b.childNode(withName:"glass",recursively:false)?.geometry,"Only immutable glass geometry is shared")
        scene.update(frames:frames,images:[:],appearance:.deepNight,selected:frames[0].id,size:CGSize(width:1440,height:900),reduced:true,day:day)
        XCTAssertTrue(a.childNode(withName:"information",recursively:false)?.geometry?.firstMaterial === aInfo,"Keep the displayed footer until its replacement is ready")
        scene.setActive(false);await scene.waitForFooters()
        XCTAssertEqual(scene.pendingFooterCount,0)
        XCTAssertEqual(scene.selectionSurface()?.0.id,frames[0].id,"Async footer preparation cannot change click/extraction identity")
    }
}
