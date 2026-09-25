import Foundation
import AVFoundation

struct AudioArchiveReference:Sendable {
    let path:String
    let url:URL
    let offset:Double
    let bytes:Int64
    let modified:Date?
    static func candidates(session:RecordingSession,root:URL)throws->[Self] {
        // Old versions did not persist which sources were enabled. Both saved
        // tracks prove coverage; a single legacy track could be a failed pair.
        let sources = session.audioSources ?? (session.systemAudioPath != nil && session.microphoneAudioPath != nil ? ["system","microphone"]:[])
        guard !sources.isEmpty else { return [] }
        var result:[Self] = []
        for name in sources {
            let path = name == "system" ? session.systemAudioPath:session.microphoneAudioPath
            let offset = name == "system" ? session.systemAudioOffset:session.microphoneAudioOffset
            guard let path else { return [] }
            let url = try CleanupFiles.ownedURL(path,root:root)
            guard FileManager.default.fileExists(atPath:url.path) else { return [] }
            result.append(Self(path:path,url:url,offset:offset ?? 0,bytes:try CleanupFiles.size(url),modified:try url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate))
        }
        return result
    }
    func validate(duration:Double)async throws {
        let asset = AVURLAsset(url:url)
        guard bytes > 0,offset.isFinite,offset >= 0,
              let track = try await asset.loadTracks(withMediaType:.audio).first else { throw RewindError.message("The independent audio is incomplete; keeping embedded audio.") }
        let range = try await track.load(.timeRange)
        guard range.duration.seconds+offset >= duration-0.25 else { throw RewindError.message("The independent audio does not cover the recording; keeping embedded audio.") }
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM])
        reader.add(output);guard reader.startReading(),output.copyNextSampleBuffer() != nil else { throw RewindError.message("The independent audio cannot be decoded; keeping embedded audio.") }
        reader.cancelReading()
    }
    func isUnchanged(root:URL)throws->Bool {
        let source = try CleanupFiles.ownedURL(path,root:root)
        return try CleanupFiles.size(source) == bytes && source.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate == modified
    }
}
