using NAudio.MediaFoundation;
using NAudio.Wave;
using Rewind;

internal static class AudioTrackEncodingTests
{
    internal static void Run(Action<bool, string> check, string root)
    {
        const int sampleRate = 48000;
        const int blockAlign = 8; // Stereo IEEE float, as used by WASAPI loopback.
        check(!AudioTrackPolicy.HasEncodableSamples(0, sampleRate, blockAlign),
            "A zero-byte WASAPI callback does not create an audio track");
        check(!AudioTrackPolicy.HasEncodableSamples(2048L * blockAlign - 1, sampleRate, blockAlign),
            "A partial encoder block is omitted instead of sent to Media Foundation");
        check(!AudioTrackPolicy.HasEncodableSamples(2048L * blockAlign, sampleRate, blockAlign) &&
              AudioTrackPolicy.HasEncodableSamples(2049L * blockAlign, sampleRate, blockAlign),
            "The exact native AAC failure boundary is excluded while 2049 samples remain available");
        check(AudioTrackPolicy.HasEncodableSamples(sampleRate * 43L / 1000 * blockAlign, sampleRate, blockAlign),
            "The shortest locally verified AAC segment is retained");
        check(AudioTrackPolicy.HasEncodableSamples(sampleRate / 10L * blockAlign, sampleRate, blockAlign),
            "A 100 ms captured audio segment is retained");
        if (!OperatingSystem.IsWindows()) return;

        Directory.CreateDirectory(root);
        var format = WaveFormat.CreateIeeeFloatWaveFormat(sampleRate, 2);
        foreach (var frames in new[] { 2049, sampleRate / 10 })
        {
            var wave = Path.Combine(root, $"system-audio-{frames}.wav");
            var aac = Path.Combine(root, $"system-audio-{frames}.m4a");
            var samples = new byte[frames * format.BlockAlign];
            for (var frame = 0; frame < frames; frame++)
            {
                var value = (float)(Math.Sin(2 * Math.PI * 440 * frame / sampleRate) * .1);
                var bytes = BitConverter.GetBytes(value);
                for (var channel = 0; channel < 2; channel++)
                    Buffer.BlockCopy(bytes, 0, samples, frame * format.BlockAlign + channel * 4, 4);
            }
            using (var writer = new WaveFileWriter(wave, format)) writer.Write(samples, 0, samples.Length);
            using (var reader = new WaveFileReader(wave)) MediaFoundationEncoder.EncodeToAac(reader, aac, 96000);
            using var decoded = new MediaFoundationReader(aac);
            var buffer = new byte[65536];
            check(new FileInfo(aac).Length > 0 && decoded.Read(buffer, 0, buffer.Length) > 0,
                $"A {frames}-sample IEEE-float loopback clip encodes and decodes as AAC");
        }
    }
}
