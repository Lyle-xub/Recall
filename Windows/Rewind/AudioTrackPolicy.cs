namespace Rewind;

internal static class AudioTrackPolicy
{
    // AAC encoders need complete sample blocks. A segment stopped while Recall
    // opens may contain no loopback samples or only a fraction of a frame.
    // Treat that as an absent optional track; an encoder error for a real track
    // must still reach the caller.
    internal static bool HasEncodableSamples(long bytes, int sampleRate, int blockAlign)
    {
        if (bytes <= 0 || sampleRate <= 0 || blockAlign <= 0) return false;
        // Media Foundation's AAC sink needs more than two 1024-sample frames.
        // The local 48 kHz probe failed at exactly 2048 and encoded 2049.
        const int minimumFrames = 2 * 1024;
        return bytes / blockAlign > minimumFrames;
    }
}
