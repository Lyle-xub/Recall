import XCTest
import Combine
@testable import Rewind

private actor ArchivePublicationDecodeGate {
    let first=XCTestExpectation(description:"First four image reads started")
    let second=XCTestExpectation(description:"Next four image reads remain held")
    private var count=0
    private var continuations:[CheckedContinuation<CGImage?,Never>]=[]
    init() {first.expectedFulfillmentCount=4;second.expectedFulfillmentCount=4}
    func decode()async->CGImage? {
        count += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
            if count <= 4 {first.fulfill()} else {second.fulfill()}
        }
    }
    func release() {
        let pixels=CGContext(data:nil,width:80,height:50,bitsPerComponent:8,bytesPerRow:320,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let pending=continuations;continuations=[]
        pending.forEach {$0.resume(returning:pixels)}
    }
}

final class ArchiveImagePublicationTests:XCTestCase {
    @MainActor func testSlowRemainingImagesCannotStarveCompletedVisiblePixels()async {
        let gate=ArchivePublicationDecodeGate()
        let frames=(0..<8).map {index in MemoryFrame(id:"\(index)",timestamp:Date(),appName:"Fixture",bundleID:"test",title:"",imagePath:"\(index).png",text:"",regions:[])}
        let loader=ArchiveImageLoader(decode:{_ in await gate.decode()})
        defer {loader.stop()}
        let partial=expectation(description:"Completed pixels publish while the second batch is blocked")
        let subscription=loader.$images.filter {!$0.isEmpty}.prefix(1).sink {_ in partial.fulfill()}
        loader.request(frames,viewport:.init(visible:Set(frames.map(\.id))),root:URL(fileURLWithPath:"/synthetic"))
        await fulfillment(of:[gate.first],timeout:2)
        await gate.release()
        await fulfillment(of:[gate.second,partial],timeout:2)
        XCTAssertEqual(loader.images.count,4,"A later disk read cannot hold back already decoded visible cards")
        await gate.release();await loader.waitUntilIdle()
        XCTAssertEqual(loader.images.count,8)
        XCTAssertEqual(loader.publicationCount,2,"Publish a bounded cohort, not one update per image")
        withExtendedLifetime(subscription) {}
    }
}
