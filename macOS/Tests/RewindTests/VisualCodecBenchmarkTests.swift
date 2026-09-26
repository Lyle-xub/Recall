import XCTest
import AVFoundation
import VideoToolbox
import CoreImage
import Darwin
@testable import Rewind

/// Opt-in, read-only source sequence. Encoded candidates are disposable files.
final class VisualCodecBenchmarkTests:XCTestCase {
    struct Sequence:Decodable {let root:String;let sessions:[RecordingSession];let frames:[MemoryFrame]}
    func testCompletedLiveRecordingBudget()throws {
        guard let directory=ProcessInfo.processInfo.environment["RECALL_VISUAL_BENCHMARK"] else {throw XCTSkip("Opt-in isolated live-recording audit")}
        let folder=URL(fileURLWithPath:directory),sourceRoot=folder.appendingPathComponent("live-library"),root=folder.appendingPathComponent("live-settled-library")
        guard FileManager.default.fileExists(atPath:sourceRoot.appendingPathComponent(".benchmark-copy").path),!FileManager.default.fileExists(atPath:root.path) else {throw XCTSkip("Requires an isolated test recording and a fresh audit directory")}
        let source=try MemoryStore(root:sourceRoot,readOnly:true)
        let sessions=try source.sessions().filter {$0.visualArchiveReady==true && $0.endedAt != nil}
        XCTAssertFalse(sessions.isEmpty)
        let ids=Set(sessions.map(\.id)),frames=try source.frames(demo:false,limit:10_000).filter {$0.sessionID.map(ids.contains)==true}
        XCTAssertTrue(frames.allSatisfy {$0.indexingComplete==true && $0.imagePath.hasSuffix(".recallvideo")},"Count all originals if OCR has not caught up")
        var target:MemoryStore?=try MemoryStore(root:root),paths=Set<String>()
        for session in sessions {
            try target!.saveSession(session)
            paths.formUnion([session.videoPath,session.systemAudioPath,session.microphoneAudioPath].compactMap {$0})
            for line in try source.transcript(session.id) {try target!.saveTranscript(line)}
            for interval in try source.usage(in:DateInterval(start:session.startedAt,end:session.endedAt!)) {try target!.saveUsage(interval)}
        }
        for frame in frames {
            var copy=frame;copy.imagePath="frames/source-audit-\(frame.id).png"
            try target!.save(copy)
            if let meeting=frame.meetingImagePath {paths.insert(meeting)}
        }
        for path in paths {try FileManager.default.copyItem(at:CleanupFiles.ownedURL(path,root:sourceRoot),to:CleanupFiles.ownedURL(path,root:root))}
        for session in sessions {_=try target!.finalizeVisualSession(session.id)}
        try target!.compactIndex();target=nil
        var sizes:[String:Int64]=[:]
        let files=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])!
        while let file=files.nextObject() as? URL {
            guard try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true else {continue}
            let kind=file.pathExtension=="mp4" ? "visual":file.pathExtension=="m4a" ? "audio":file.pathExtension=="recallvideo" ? "references":"databaseAndOther"
            sizes[kind,default:0] += try CleanupFiles.size(file)
        }
        let duration=sessions.reduce(0) {$0+$1.endedAt!.timeIntervalSince($1.startedAt)}
        let values:[String:Any]=["recordedSeconds":duration,"frames":frames.count,"allocatedBytes":sizes,"totalMBPerHour":Double(sizes.values.reduce(0,+))/duration*3600/1_000_000]
        print("LIVE_SETTLED_BUDGET \(values)")
        try JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("live-settled-budget.json"))
    }
    func testRandomCardDecoding()throws {
        guard let directory=ProcessInfo.processInfo.environment["RECALL_VISUAL_BENCHMARK"] else {throw XCTSkip("Opt-in native card decoder benchmark")}
        let folder=URL(fileURLWithPath:directory),root=folder.appendingPathComponent("unified-production")
        let store=try MemoryStore(root:root,readOnly:true),frames=try store.frames(demo:false,limit:1000)
        XCTAssertGreaterThan(frames.count,60)
        var samples:[Double]=[]
        let cpu=clock()
        for index in 0..<60 {
            try autoreleasepool {
                let frame=frames[(index*37)%frames.count],start=Date()
                let pixels=try XCTUnwrap(StoredImage.load(root.appendingPathComponent(frame.imagePath),maxPixels:index%10==0 ? nil:560))
                samples.append(Date().timeIntervalSince(start)*1000)
                if index%10==0 {XCTAssertEqual(pixels.width,frame.visualWidth)} else {XCTAssertLessThanOrEqual(max(pixels.width,pixels.height),560)}
            }
        }
        let values:[String:Any]=["reads":samples.count,"p50MS":samples.sorted()[30],"p95MS":samples.sorted()[57],"cpuSeconds":Double(clock()-cpu)/Double(CLOCKS_PER_SEC)]
        print("VISUAL_RANDOM_CARDS \(values)")
        try JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("random-cards.json"))
    }
    func testProductionEncoderSequence()async throws {
        guard let directory=ProcessInfo.processInfo.environment["RECALL_VISUAL_BENCHMARK"] else {throw XCTSkip("Opt-in production encoder comparison")}
        let folder=URL(fileURLWithPath:directory),sequence=try JSONDecoder().decode(Sequence.self,from:Data(contentsOf:folder.appendingPathComponent("sequence.json")))
        var times:[String:Double]=[:],bytes:Int64=0,duration=0.0,encodedCPU=0.0
        for (index,session) in sequence.sessions.enumerated() {
            let frames=sequence.frames.filter {$0.sessionID==session.id},url=folder.appendingPathComponent("production-\(index).mp4")
            let first=try XCTUnwrap(frames.first),image=try XCTUnwrap(StoredImage.load(URL(fileURLWithPath:sequence.root).appendingPathComponent(first.imagePath)))
            if FileManager.default.fileExists(atPath:url.path) {try FileManager.default.removeItem(at:url)}
            var sink:LightweightVideoSink?=try LightweightVideoSink(url:url,width:image.width,height:image.height,startedAt:session.startedAt,hostStart:.zero,nativeArchive:true)
            var held=CIImage(cgImage:image),tick=0.0
            for frame in frames {
                let pixels=try XCTUnwrap(StoredImage.load(URL(fileURLWithPath:sequence.root).appendingPathComponent(frame.imagePath)))
                let time=frame.timestamp.timeIntervalSince(session.startedAt),before=clock()
                // Existing native screenshots were sampled every ~3 seconds.
                // Hold between those observations at the replay cadence; this
                // measures extra replay packets, not unseen intermediate motion.
                while tick<time {
                    sink!.queue.sync {_=sink!.consume(held,at:CMTime(seconds:tick,preferredTimescale:600))};tick += 1
                }
                held=CIImage(cgImage:pixels)
                let stamp=sink!.queue.sync {sink!.consume(held,at:CMTime(seconds:time,preferredTimescale:600),force:true)}
                times[frame.id]=try XCTUnwrap(stamp).seconds
                encodedCPU += Double(clock()-before)/Double(CLOCKS_PER_SEC)
            }
            let end=try XCTUnwrap(session.endedAt),length=end.timeIntervalSince(session.startedAt)
            try await sink!.finish(at:end);sink=nil
            bytes += try CleanupFiles.size(url);duration += length
        }
        try JSONEncoder().encode(times).write(to:folder.appendingPathComponent("production-times.json"))
        let values:[String:Any]=["allocatedBytes":bytes,"recordedSeconds":duration,"MBPerHour":Double(bytes)/duration*3600/1_000_000,"encodeCPUSeconds":encodedCPU]
        print("PRODUCTION_ENCODER \(values)")
        try JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("production-encoder.json"))
    }
    func testCurrentCompactBudget()throws {
        guard let directory=ProcessInfo.processInfo.environment["RECALL_VISUAL_BENCHMARK"] else {throw XCTSkip("Opt-in compact comparison")}
        let folder=URL(fileURLWithPath:directory),root=folder.appendingPathComponent("compact-library")
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent(".benchmark-copy").path) else {throw XCTSkip("Requires a prepared comparison copy")}
        var store:MemoryStore?=try MemoryStore(root:root)
        while try store!.packLegacyTiles().more { }
        try store!.compactIndex();store=nil
        let sequence=try JSONDecoder().decode(Sequence.self,from:Data(contentsOf:folder.appendingPathComponent("sequence.json")))
        let duration=sequence.sessions.reduce(0) {$0+($1.endedAt?.timeIntervalSince($1.startedAt) ?? 0)}
        var sizes:[String:Int64]=[:]
        let files=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])!
        while let file=files.nextObject() as? URL {
            guard try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true else {continue}
            let name=file.path.contains("/frames/") ? "screenshots":file.pathExtension=="mp4" ? "replay":file.pathExtension=="m4a" ? "audio":"databaseAndOther"
            sizes[name,default:0] += try CleanupFiles.size(file)
        }
        let values:[String:Any]=["allocatedBytes":sizes,"recordedSeconds":duration,"totalMBPerHour":Double(sizes.values.reduce(0,+))/duration*3600/1_000_000]
        try JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("compact-budget.json"))
        print("COMPACT_TOTAL_BUDGET \(values)")
    }
    func testCompleteArchiveBudget()async throws {
        guard let directory=ProcessInfo.processInfo.environment["RECALL_VISUAL_BENCHMARK"] else {throw XCTSkip("Opt-in complete recording budget")}
        let folder=URL(fileURLWithPath:directory),sequence=try JSONDecoder().decode(Sequence.self,from:Data(contentsOf:folder.appendingPathComponent("sequence.json")))
        let candidateName=ProcessInfo.processInfo.environment["RECALL_VISUAL_CANDIDATE"] ?? "hvc1-q0.5-g60"
        let times=(try? JSONDecoder().decode([String:Double].self,from:Data(contentsOf:folder.appendingPathComponent(candidateName+"-times.json")))) ?? [:]
        let root=folder.appendingPathComponent("unified-"+candidateName)
        guard !FileManager.default.fileExists(atPath:root.path) else {throw XCTSkip("Use a fresh disposable output directory")}
        let original=try MemoryStore(root:URL(fileURLWithPath:sequence.root),readOnly:true)
        var store:MemoryStore?=try MemoryStore(root:root)
        var duration=0.0
        for (index,sourceSession) in sequence.sessions.enumerated() {
            var session=sourceSession
            let candidate=folder.appendingPathComponent("\(candidateName)-\(index).mp4")
            session.videoPath="recordings/\(session.id).mp4";session.unifiedVisualArchive=true;session.visualArchiveReady=true
            session.storagePolicy=3;session.videoOptimizationVersion=VideoArchive.policyVersion
            try FileManager.default.copyItem(at:candidate,to:root.appendingPathComponent(session.videoPath))
            for path in [session.systemAudioPath,session.microphoneAudioPath].compactMap({$0}) {
                try FileManager.default.copyItem(at:URL(fileURLWithPath:sequence.root).appendingPathComponent(path),to:root.appendingPathComponent(path))
            }
            try store!.saveSession(session)
            for line in try original.transcript(sourceSession.id) {try store!.saveTranscript(line)}
            for interval in try original.usage(in:DateInterval(start:session.startedAt,end:session.endedAt!)) {try store!.saveUsage(interval)}
            let track=try await AVURLAsset(url:candidate).loadTracks(withMediaType:.video).first
            let size=try await XCTUnwrap(track).load(.naturalSize)
            for source in sequence.frames.filter({$0.sessionID==session.id}) {
                var frame=try XCTUnwrap(original.frame(source.id))
                frame.regions=CompactOCR.identified((frame.text,frame.regions)).1
                frame.meetingRegions=CompactOCR.identified(("",frame.meetingRegions)).1
                frame.visualTime=times[frame.id] ?? frame.timestamp.timeIntervalSince(session.startedAt);frame.visualWidth=Int(size.width);frame.visualHeight=Int(size.height)
                try store!.save(frame)
            }
            let frames=try store!.finalizeVisualSession(session.id)
            for frame in frames {
                let old=try XCTUnwrap(original.frame(frame.id))
                XCTAssertEqual(frame.regions,CompactOCR.identified((old.text,old.regions)).1);XCTAssertEqual(frame.text,old.text)
            }
            duration += try XCTUnwrap(session.endedAt).timeIntervalSince(session.startedAt)
        }
        try store!.compactIndex();store=nil
        var categories:[String:Int64]=[:]
        let files=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])!
        while let url=files.nextObject() as? URL {
            guard try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true else {continue}
            let category=url.pathExtension=="mp4" ? "visual":url.pathExtension=="m4a" ? "audio":url.pathExtension=="recallvideo" ? "references":"databaseAndOther"
            categories[category,default:0] += try CleanupFiles.size(url)
        }
        let bytes=categories.values.reduce(0,+),hour=Double(bytes)/duration*3600/1_000_000
        let values:[String:Any]=["candidate":candidateName,"allocatedBytes":categories,"totalBytes":bytes,"recordedSeconds":duration,"totalMBPerHour":hour,"GBPer240Hours":hour*240/1000,"frames":sequence.frames.count,"fixedModelsIncluded":false]
        print("VISUAL_TOTAL_BUDGET \(values)")
        try JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("total-budget.json"))
    }
    func testContinuousSequence()async throws {
        guard let directory=ProcessInfo.processInfo.environment["RECALL_VISUAL_BENCHMARK"] else {throw XCTSkip("Opt-in continuous private recording benchmark")}
        let folder=URL(fileURLWithPath:directory),sequence=try JSONDecoder().decode(Sequence.self,from:Data(contentsOf:folder.appendingPathComponent("sequence.json")))
        let context=CIContext(options:[.cacheIntermediates:false]),space=CGColorSpace(name:CGColorSpace.sRGB)!
        var results:[[String:Any]]=[]
        let tuning=ProcessInfo.processInfo.environment["RECALL_VISUAL_TUNING"] == "1"
        let configurations:[(AVVideoCodecType,Double,Double)] = tuning ? [(.hevc,0.55,90),(.hevc,0.5,60)]:[(.h264,0.55,15),(.hevc,0.55,15),(.hevc,0.7,15),(.hevc,0.55,60)]
        for (codec,quality,keyInterval) in configurations {
            let name="\(codec.rawValue)-q\(quality)-g\(Int(keyInterval))"
            var bytes:Int64=0,seconds=0.0,encodeCPU=0.0,decodeCPU=0.0,wall=0.0,reads:[Double]=[]
            for (segment,session) in sequence.sessions.enumerated() {
                let frames=sequence.frames.filter {$0.sessionID==session.id}
                guard let first=frames.first else {continue}
                let firstImage=try XCTUnwrap(StoredImage.load(URL(fileURLWithPath:sequence.root).appendingPathComponent(first.imagePath)))
                let url=folder.appendingPathComponent("\(name)-\(segment).mp4")
                if FileManager.default.fileExists(atPath:url.path) {try FileManager.default.removeItem(at:url)}
                let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
                let settings:[String:Any]=[AVVideoCodecKey:codec,AVVideoWidthKey:firstImage.width,AVVideoHeightKey:firstImage.height,
                    AVVideoEncoderSpecificationKey:[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String:true],
                    AVVideoCompressionPropertiesKey:[kVTCompressionPropertyKey_Quality as String:quality,AVVideoExpectedSourceFrameRateKey:1,AVVideoMaxKeyFrameIntervalDurationKey:keyInterval,AVVideoAllowFrameReorderingKey:false]]
                let input=AVAssetWriterInput(mediaType:.video,outputSettings:settings)
                let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:firstImage.width,kCVPixelBufferHeightKey as String:firstImage.height,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
                writer.add(input);XCTAssertTrue(writer.startWriting());writer.startSession(atSourceTime:.zero)
                let start=Date();var last:CVPixelBuffer?
                for frame in frames {
                    let beforeDecode=clock()
                    let image=try XCTUnwrap(StoredImage.load(URL(fileURLWithPath:sequence.root).appendingPathComponent(frame.imagePath)))
                    decodeCPU += Double(clock()-beforeDecode)/Double(CLOCKS_PER_SEC)
                    let before=clock()
                    while !input.isReadyForMoreMediaData {if writer.status == .failed {throw writer.error!};try await Task.sleep(for:.milliseconds(2))}
                    var pixel:CVPixelBuffer?
                    XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil,try XCTUnwrap(adaptor.pixelBufferPool),&pixel),kCVReturnSuccess)
                    let buffer=try XCTUnwrap(pixel)
                    context.render(CIImage(cgImage:image),to:buffer,bounds:CGRect(x:0,y:0,width:image.width,height:image.height),colorSpace:space)
                    XCTAssertTrue(adaptor.append(buffer,withPresentationTime:CMTime(seconds:frame.timestamp.timeIntervalSince(session.startedAt),preferredTimescale:600)))
                    last=buffer;encodeCPU += Double(clock()-before)/Double(CLOCKS_PER_SEC)
                }
                let duration=try XCTUnwrap(session.endedAt).timeIntervalSince(session.startedAt),before=clock()
                while !input.isReadyForMoreMediaData {try await Task.sleep(for:.milliseconds(2))}
                if let last {XCTAssertTrue(adaptor.append(last,withPresentationTime:CMTime(seconds:duration-0.001,preferredTimescale:600)))}
                writer.endSession(atSourceTime:CMTime(seconds:duration,preferredTimescale:600));input.markAsFinished();await writer.finishWriting()
                XCTAssertEqual(writer.status,.completed,"\(String(describing:writer.error))")
                encodeCPU += Double(clock()-before)/Double(CLOCKS_PER_SEC)
                bytes += try CleanupFiles.size(url);seconds += duration;wall += Date().timeIntervalSince(start)
                let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
                for i in 0..<min(10,frames.count) {
                    let frame=frames[(i*37)%frames.count],time=CMTime(seconds:frame.timestamp.timeIntervalSince(session.startedAt),preferredTimescale:600),begin=Date()
                    let decoded=try await generator.image(at:time).image
                    reads.append(Date().timeIntervalSince(begin)*1000)
                    if i == 4 {
                        try ScreenArchive.encode(decoded,type:.png).write(to:folder.appendingPathComponent("\(name)-\(segment)-decoded.png"))
                        let original=try XCTUnwrap(StoredImage.load(URL(fileURLWithPath:sequence.root).appendingPathComponent(frame.imagePath)))
                        try ScreenArchive.encode(original,type:.png).write(to:folder.appendingPathComponent("source-\(segment).png"))
                    }
                }
            }
            let result:[String:Any]=["name":name,"allocatedBytes":bytes,"recordedSeconds":seconds,"MBPerHour":Double(bytes)/seconds*3600/1_000_000,"encodeCPUSeconds":encodeCPU,"sourceDecodeCPUSeconds":decodeCPU,"wallSeconds":wall,"randomP95MS":reads.sorted()[Int(Double(reads.count-1)*0.95)]]
            results.append(result);print("VISUAL_CODEC \(result)")
            try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent(tuning ? "codec-tuning-results.json":"codec-results.json"))
        }
    }
}
