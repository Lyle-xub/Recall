import AVFoundation

/// A composition references the original AAC files; it creates no merged file
/// and performs no audio re-encoding. Source offsets share the capture clock.
enum RecordingPlayback {
    static func asset(session:RecordingSession,root:URL)async throws->AVAsset {
        let video = AVURLAsset(url:root.appendingPathComponent(session.videoPath))
        guard session.usesExternalAudio == true else { return video }
        let composition = AVMutableComposition(),duration = try await video.load(.duration)
        guard let source = try await video.loadTracks(withMediaType:.video).first,
              let target = composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw RewindError.message("This recording has no playable video.") }
        try target.insertTimeRange(CMTimeRange(start:.zero,duration:duration),of:source,at:.zero)
        target.preferredTransform = try await source.load(.preferredTransform)
        for (path,offset) in [(session.systemAudioPath,session.systemAudioOffset ?? 0),(session.microphoneAudioPath,session.microphoneAudioOffset ?? 0)] {
            guard let path else { continue }
            let audio = AVURLAsset(url:root.appendingPathComponent(path)),start = CMTime(seconds:max(0,offset),preferredTimescale:48000)
            for track in try await audio.loadTracks(withMediaType:.audio) {
                let available = try await track.load(.timeRange)
                let length = CMTimeMinimum(available.duration,CMTimeSubtract(duration,start))
                guard length > .zero,let target = composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { continue }
                try target.insertTimeRange(CMTimeRange(start:available.start,duration:length),of:track,at:start)
            }
        }
        return composition
    }
}
