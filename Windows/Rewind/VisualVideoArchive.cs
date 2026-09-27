using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using NAudio.MediaFoundation;
using Rectangle = System.Drawing.Rectangle;

namespace Rewind;

// All writer calls come from CaptureService's ordered capture loop. A sample is
// copied from the SAME bitmap as its OCR spool; wall-clock matching is never used.
public sealed class VisualVideoWriter : IDisposable
{
    private IMFSinkWriter? writer;
    private int stream;
    private byte[]? pending;
    private long pendingTicks;
    private bool finished, failed;
    private long writtenSamples;
    private readonly string path;
    private static string? unavailableHevc;
    internal static void DisableHevc(string reason) => Interlocked.Exchange(ref unavailableHevc, reason);
    public int Width { get; }
    public int Height { get; }
    public long SampleCount { get; private set; }
    public long DurationTicks { get; private set; }
    public string Codec { get; private set; } = "";
    public string? Diagnostic { get; private set; }
    internal string TransformDiagnostic { get; private set; } = "";
    internal int EncodedWidth => (Width + 1) & ~1;
    internal int EncodedHeight => (Height + 1) & ~1;

    public VisualVideoWriter(string path, int width, int height, bool preferHevc = true)
        : this(path, width, height, preferHevc, NativeVideo.HasHardwareHevc) { }

    internal VisualVideoWriter(string path, int width, int height, bool preferHevc, Func<bool> hasHardwareHevc)
    {
        if (width <= 0 || height <= 0 || width > 16000 || height > 16000 || (long)width * height > 40_000_000)
            throw new InvalidDataException("Invalid native capture dimensions.");
        this.path = path; Width = width; Height = height;
        NativeVideo.Startup();
        if (preferHevc)
        {
            try
            {
                if (unavailableHevc is { } unavailable) throw new InvalidOperationException(unavailable);
                if (!hasHardwareHevc()) throw new InvalidOperationException("Hardware HEVC encoding and compatible decoding are unavailable.");
                Open(NativeVideo.Hevc); Codec = "hevc"; return;
            }
            catch (Exception ex) when (ex is COMException or InvalidOperationException)
            {
                NativeVideo.Release(writer); writer = null;
                if (File.Exists(path)) File.Delete(path);
                Diagnostic = $"HEVC encoding is unavailable (0x{ex.HResult:X8}); using full-resolution H.264. Hardware encoding is enabled when supported.";
            }
        }
        try { Open(NativeVideo.H264); Codec = "h264"; }
        catch
        {
            NativeVideo.Release(writer); writer = null;
            if (File.Exists(path)) File.Delete(path);
            throw;
        }
    }

    private void Open(Guid codec)
    {
        var attributes = MediaFoundationApi.CreateAttributes(2);
        IMFMediaType? output = null, input = null;
        IMFAttributes? parameters = null;
        try
        {
            attributes.SetUINT32(MediaFoundationAttributes.MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1);
            attributes.SetUINT32(MediaFoundationAttributes.MF_SINK_WRITER_DISABLE_THROTTLING, 1);
            MediaFoundationInterop.MFCreateSinkWriterFromURL(path, null!, attributes, out writer);
            output = NativeVideo.Type(codec, EncodedWidth, EncodedHeight);
            // Quality mode is the archive policy; the bitrate is a compatibility
            // hint for encoders requiring one, never the old 720px replay cap.
            output.SetUINT32(MediaFoundationAttributes.MF_MT_AVG_BITRATE, Math.Clamp(checked(EncodedWidth * EncodedHeight * 2), 1_000_000, 30_000_000));
            writer.AddStream(output, out stream);
            input = NativeVideo.Type(NativeVideo.Rgb32, EncodedWidth, EncodedHeight);
            input.SetUINT32(NativeVideo.Stride, EncodedWidth * 4);
            parameters = MediaFoundationApi.CreateAttributes(4);
            parameters.SetUINT32(NativeVideo.RateControl, 3); // quality-based VBR
            parameters.SetUINT32(NativeVideo.Quality, 50);
            parameters.SetUINT32(NativeVideo.Gop, 60);
            parameters.SetUINT32(NativeVideo.BFrames, 0);
            writer.SetInputMediaType(stream, input, parameters);
            TransformDiagnostic = NativeVideo.DisableFrameRateConversion(writer, stream);
            writer.BeginWriting();
        }
        finally { NativeVideo.Release(parameters); NativeVideo.Release(input); NativeVideo.Release(output); NativeVideo.Release(attributes); }
    }

    public long Append(Bitmap source, long requestedTicks)
    {
        if (finished || failed || writer == null) throw new InvalidOperationException("The visual archive writer is closed.");
        if (source.Width != Width || source.Height != Height) throw new InvalidOperationException("The display dimensions changed. Start a new recording segment.");
        // Millisecond precision survives MP4 timebase conversion. These are the
        // actual submitted sample times, not a later estimate from frame dates.
        var ticks = SampleCount == 0 ? 0 : Math.Max(pendingTicks + TimeSpan.TicksPerMillisecond, requestedTicks / TimeSpan.TicksPerMillisecond * TimeSpan.TicksPerMillisecond);
        var pixels = new byte[checked(EncodedWidth * EncodedHeight * 4)];
        var data = source.LockBits(new Rectangle(0, 0, Width, Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            for (int y = 0; y < Height; y++)
            {
                Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), pixels, y * EncodedWidth * 4, Width * 4);
                // Even codec dimensions are padded by repeating the right/bottom
                // edge. Archive metadata retains the unscaled original extent.
                if (EncodedWidth != Width) Buffer.BlockCopy(pixels, (y * EncodedWidth + Width - 1) * 4, pixels, (y * EncodedWidth + Width) * 4, 4);
            }
            if (EncodedHeight != Height) Buffer.BlockCopy(pixels, (Height - 1) * EncodedWidth * 4, pixels, Height * EncodedWidth * 4, EncodedWidth * 4);
        }
        finally { source.UnlockBits(data); }
        try
        {
            if (pending != null) WritePending(ticks - pendingTicks);
            pending = pixels; pendingTicks = ticks; SampleCount++;
            return ticks;
        }
        catch { failed = true; throw; }
    }

    private void WritePending(long duration)
    {
        var buffer = MediaFoundationApi.CreateMemoryBuffer(pending!.Length);
        IMFSample? sample = null;
        try
        {
            buffer.Lock(out var pointer, out _, out _);
            try { Marshal.Copy(pending, 0, pointer, pending.Length); }
            finally { buffer.Unlock(); }
            buffer.SetCurrentLength(pending.Length);
            sample = MediaFoundationApi.CreateSample();
            sample.AddBuffer(buffer);
            sample.SetSampleTime(pendingTicks);
            sample.SetSampleDuration(Math.Max(TimeSpan.TicksPerMillisecond, duration));
            try { writer!.WriteSample(stream, sample); }
            catch (COMException ex) when (Codec == "hevc" && writtenSamples == 0)
            {
                // Some drivers accept the type but reject the first pixels.
                // Only retry before any sample was written: all pixels needed
                // to recreate this segment are still in the bounded pending slot.
                NativeVideo.Release(writer); writer = null;
                if (File.Exists(path)) File.Delete(path);
                Open(NativeVideo.H264); Codec = "h264";
                Diagnostic = $"The HEVC encoder rejected its first sample (0x{ex.HResult:X8}); using full-resolution H.264.";
                writer!.WriteSample(stream, sample);
            }
            writtenSamples++;
        }
        finally { NativeVideo.Release(sample); NativeVideo.Release(buffer); }
    }

    public void Finish(long endTicks)
    {
        if (finished || failed || writer == null || pending == null) throw new InvalidOperationException("The visual archive has no complete video samples. Original captures were retained.");
        finished = true;
        try
        {
            DurationTicks = Math.Max(pendingTicks + TimeSpan.TicksPerMillisecond, endTicks);
            WritePending(DurationTicks - pendingTicks);
            writer.DoFinalize();
            // Finalize closes the container; then force its bytes to durable
            // storage before any card can replace its retained lossless image.
            NativeVideo.Release(writer); writer = null; pending = null;
            using var file = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read);
            if (file.Length == 0) throw new InvalidDataException("The finalized video is empty.");
            file.Flush(true);
        }
        catch { failed = true; throw; }
    }

    public void Dispose()
    {
        finished = true; pending = null;
        NativeVideo.Release(writer); writer = null;
    }
}

public static class VisualVideoReader
{
    // No unbounded decoder/cache per thumbnail. Two native decoders maximum,
    // each released after the requested sample, including every failure path.
    private static readonly SemaphoreSlim slots = new(2, 2);
    public static Bitmap Load(string root, VisualArchive reference, int maxEdge = 0, CancellationToken cancellation = default)
    {
        var video = reference.Validate(root);
        slots.Wait(cancellation);
        try { return Decode(video, reference, maxEdge, cancellation); }
        finally { slots.Release(); }
    }

    public static bool Verify(string root, VisualArchive reference, CancellationToken cancellation = default)
    {
        try { using var image = Load(root, reference, cancellation: cancellation); return image.Width == reference.Width && image.Height == reference.Height; }
        catch (Exception ex) when (ex is COMException or IOException or InvalidOperationException or ArgumentException) { return false; }
    }

    private static Bitmap Decode(string path, VisualArchive reference, int maxEdge, CancellationToken cancellation)
    {
        NativeVideo.Startup();
        IMFSourceReader? reader = null;
        IMFMediaType? requested = null;
        var attributes = MediaFoundationApi.CreateAttributes(2);
        try
        {
            attributes.SetUINT32(NativeVideo.VideoProcessing, 1);
            attributes.SetUINT32(MediaFoundationAttributes.MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1);
            MediaFoundationInterop.MFCreateSourceReaderFromURL(path, attributes, out reader);
            var index = MediaFoundationInterop.MF_SOURCE_READER_FIRST_VIDEO_STREAM;
            reader.SetStreamSelection(MediaFoundationInterop.MF_SOURCE_READER_ALL_STREAMS, false);
            reader.SetStreamSelection(index, true);
            reader.GetNativeMediaType(index, 0, out var nativeType);
            (int Width, int Height) nativeSize;
            try { nativeSize = NativeVideo.PresentationExtent(nativeType); }
            finally { NativeVideo.Release(nativeType); }
            if (!NativeVideo.MatchesArchiveExtent(nativeSize.Width, nativeSize.Height, reference))
                throw new InvalidDataException($"Video presentation dimensions differ from the archive (native {nativeSize.Width}x{nativeSize.Height}; archive {reference.Width}x{reference.Height}).");
            requested = MediaFoundationApi.CreateMediaType();
            requested.SetGUID(MediaFoundationAttributes.MF_MT_MAJOR_TYPE, MediaTypes.MFMediaType_Video);
            requested.SetGUID(MediaFoundationAttributes.MF_MT_SUBTYPE, NativeVideo.Rgb32);
            reader.SetCurrentMediaType(index, IntPtr.Zero, requested);
            var time = checked((long)((decimal)reference.Ticks * TimeSpan.TicksPerSecond / reference.Timescale));
            // PROPVARIANT VT_I8 is 24 bytes on x64, with the value at offset 8.
            var position = Marshal.AllocCoTaskMem(24);
            try
            {
                for (int i = 0; i < 24; i++) Marshal.WriteByte(position, i, 0);
                Marshal.WriteInt16(position, 20); Marshal.WriteInt64(position, 8, time);
                reader.SetCurrentPosition(Guid.Empty, position);
            }
            finally { Marshal.FreeCoTaskMem(position); }
            var deadline = Stopwatch.StartNew();
            var observed = new List<string>();
            // Seeking lands on a preceding keyframe. Accept only the exact
            // decoded sample; a nearby thumbnail must never prove durability.
            for (int count = 0; count < 1200 && deadline.Elapsed < TimeSpan.FromSeconds(15); count++)
            {
                cancellation.ThrowIfCancellationRequested();
                reader.ReadSample(index, 0, out _, out var flags, out var timestamp, out var sample);
                try
                {
                    if (sample != null)
                    {
                        sample.GetSampleTime(out var sampleTime);
                        if (observed.Count < 24) observed.Add($"sample={sampleTime},reader={timestamp},flags={flags}");
                        if (sampleTime == time)
                        {
                            reader.GetCurrentMediaType(index, out var actual);
                            try { return Pixels(sample, actual, reference, nativeSize.Width, nativeSize.Height, maxEdge); }
                            finally { NativeVideo.Release(actual); }
                        }
                        if (sampleTime > time) break;
                    }
                    if (sample == null && observed.Count < 24) observed.Add($"no-sample,reader={timestamp},flags={flags}");
                    if ((flags & MF_SOURCE_READER_FLAG.MF_SOURCE_READERF_ENDOFSTREAM) != 0) break;
                }
                finally { NativeVideo.Release(sample); }
            }
            throw new InvalidDataException($"The exact visual archive sample is unavailable (expected {time}; observed [{string.Join("; ", observed)}]). The original image must be retained.");
        }
        finally { NativeVideo.Release(requested); NativeVideo.Release(reader); NativeVideo.Release(attributes); }
    }

    // Synthetic Windows test diagnostics distinguish muxer timestamp changes
    // from decoder or seek behavior without ever accepting a nearby sample.
    internal static string InspectSamples(string path, bool decode, long? seekTicks = null)
    {
        NativeVideo.Startup();
        IMFSourceReader? reader = null;
        IMFMediaType? requested = null;
        var attributes = MediaFoundationApi.CreateAttributes(2);
        var observations = new List<object>();
        object? nativeFormat = null, actualFormat = null;
        try
        {
            attributes.SetUINT32(NativeVideo.VideoProcessing, 1);
            attributes.SetUINT32(MediaFoundationAttributes.MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1);
            MediaFoundationInterop.MFCreateSourceReaderFromURL(path, attributes, out reader);
            var index = MediaFoundationInterop.MF_SOURCE_READER_FIRST_VIDEO_STREAM;
            reader.SetStreamSelection(MediaFoundationInterop.MF_SOURCE_READER_ALL_STREAMS, false);
            reader.SetStreamSelection(index, true);
            reader.GetNativeMediaType(index, 0, out var native);
            try { nativeFormat = NativeVideo.DescribeType(native); }
            finally { NativeVideo.Release(native); }
            if (decode)
            {
                requested = MediaFoundationApi.CreateMediaType();
                requested.SetGUID(MediaFoundationAttributes.MF_MT_MAJOR_TYPE, MediaTypes.MFMediaType_Video);
                requested.SetGUID(MediaFoundationAttributes.MF_MT_SUBTYPE, NativeVideo.Rgb32);
                reader.SetCurrentMediaType(index, IntPtr.Zero, requested);
            }
            if (seekTicks is { } seek)
            {
                var position = Marshal.AllocCoTaskMem(24);
                try
                {
                    for (int i = 0; i < 24; i++) Marshal.WriteByte(position, i, 0);
                    Marshal.WriteInt16(position, 20); Marshal.WriteInt64(position, 8, seek);
                    reader.SetCurrentPosition(Guid.Empty, position);
                }
                finally { Marshal.FreeCoTaskMem(position); }
            }
            for (int i = 0; i < 32; i++)
            {
                reader.ReadSample(index, 0, out _, out var flags, out var timestamp, out var sample);
                try
                {
                    long? sampleTime = null, duration = null;
                    if (sample != null)
                    {
                        sample.GetSampleTime(out var pts); sampleTime = pts;
                        try { sample.GetSampleDuration(out var span); duration = span; } catch (COMException) { }
                    }
                    reader.GetCurrentMediaType(index, out var actual);
                    try { actualFormat = NativeVideo.DescribeType(actual); }
                    finally { NativeVideo.Release(actual); }
                    observations.Add(new { ReaderTicks = timestamp, SampleTicks = sampleTime, DurationTicks = duration, Flags = flags.ToString() });
                    if ((flags & MF_SOURCE_READER_FLAG.MF_SOURCE_READERF_ENDOFSTREAM) != 0) break;
                }
                finally { NativeVideo.Release(sample); }
            }
            return System.Text.Json.JsonSerializer.Serialize(new { Decode = decode, SeekTicks = seekTicks, NativeFormat = nativeFormat, ActualFormat = actualFormat, Samples = observations });
        }
        catch (Exception error) { return System.Text.Json.JsonSerializer.Serialize(new { Decode = decode, SeekTicks = seekTicks, NativeFormat = nativeFormat, ActualFormat = actualFormat, Samples = observations, Error = error.ToString() }); }
        finally { NativeVideo.Release(requested); NativeVideo.Release(reader); NativeVideo.Release(attributes); }
    }

    private static Bitmap Pixels(IMFSample sample, IMFMediaType type, VisualArchive reference, int presentationWidth, int presentationHeight, int maxEdge)
    {
        var (width, height) = NativeVideo.FrameExtent(type);
        var minimum = NativeVideo.Aperture(type, NativeVideo.MinimumAperture);
        var geometric = NativeVideo.Aperture(type, NativeVideo.GeometricAperture);
        var visible = minimum ?? geometric ?? new Rectangle(0, 0, width, height);
        // Decoder buffers may include macroblock-alignment pixels. Crop them
        // only when the type explicitly describes a valid display aperture
        // equal to the already validated native MP4 presentation dimensions.
        if (visible.Width != presentationWidth || visible.Height != presentationHeight ||
            visible.X < 0 || visible.Y < 0 || visible.Right > width || visible.Bottom > height)
            throw new InvalidDataException($"Video sample display aperture differs (archive {reference.Width}x{reference.Height}; presentation {presentationWidth}x{presentationHeight}; decoded {width}x{height}; minimum {minimum}; geometric {geometric}).");
        int stride;
        try { type.GetUINT32(NativeVideo.Stride, out stride); }
        catch (COMException) { stride = checked(-width * 4); }
        if (Math.Abs((long)stride) < width * 4L || Math.Abs((long)stride) > 1_000_000)
            throw new InvalidDataException("Invalid video sample stride.");
        sample.ConvertToContiguousBuffer(out var buffer);
        var result = new Bitmap(reference.Width, reference.Height, PixelFormat.Format32bppArgb);
        try
        {
            buffer.Lock(out var pointer, out _, out var length);
            try
            {
                if (length < Math.Abs((long)stride) * height) throw new InvalidDataException("Truncated decoded video sample.");
                var target = result.LockBits(new Rectangle(0, 0, result.Width, result.Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
                try
                {
                    var row = new byte[result.Width * 4];
                    for (int y = 0; y < result.Height; y++)
                    {
                        var sourceY = visible.Y + y;
                        var offset = (stride < 0 ? (height - 1 - sourceY) * -stride : sourceY * stride) + visible.X * 4;
                        Marshal.Copy(IntPtr.Add(pointer, offset), row, 0, row.Length);
                        for (int x = 3; x < row.Length; x += 4) row[x] = 255;
                        Marshal.Copy(row, 0, IntPtr.Add(target.Scan0, y * target.Stride), row.Length);
                    }
                }
                finally { result.UnlockBits(target); }
            }
            finally { buffer.Unlock(); }
            if (maxEdge <= 0 || Math.Max(result.Width, result.Height) <= maxEdge) return result;
            var scale = (double)maxEdge / Math.Max(result.Width, result.Height);
            var small = new Bitmap(Math.Max(1, (int)(result.Width * scale)), Math.Max(1, (int)(result.Height * scale)), PixelFormat.Format32bppArgb);
            try
            {
                using var graphics = Graphics.FromImage(small);
                graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                graphics.DrawImage(result, new Rectangle(0, 0, small.Width, small.Height));
            }
            catch { small.Dispose(); throw; }
            result.Dispose(); return small;
        }
        catch { result.Dispose(); throw; }
        finally { NativeVideo.Release(buffer); }
    }
}

// The Windows 8 extension appends one method to the eleven-method sink writer
// vtable. This exposes the automatically inserted RGB-to-YUV video processor.
[ComImport, Guid("588d72ab-5bc1-496a-8714-b70617141b25"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IVisualSinkWriterEx
{
    void AddStream(IMFMediaType type, out int stream);
    void SetInputMediaType(int stream, IMFMediaType type, IMFAttributes parameters);
    void BeginWriting();
    void WriteSample(int stream, IMFSample sample);
    void SendStreamTick(int stream, long timestamp);
    void PlaceMarker(int stream, IntPtr context);
    void NotifyEndOfSegment(int stream);
    void Flush(int stream);
    void DoFinalize();
    void GetServiceForStream(int stream, ref Guid service, ref Guid iid, out IntPtr value);
    void GetStatistics(int stream, MF_SINK_WRITER_STATISTICS statistics);
    [PreserveSig] int GetTransformForStream(int stream, int transformIndex, out Guid category, out IMFTransform transform);
}

internal static class NativeVideo
{
    internal static readonly Guid Rgb32 = new("00000016-0000-0010-8000-00aa00389b71"), H264 = new("34363248-0000-0010-8000-00aa00389b71"), Hevc = new("43564548-0000-0010-8000-00aa00389b71");
    internal static readonly Guid FrameSize = new("1652c33d-d6b2-4012-b834-72030849a37d"), FrameRate = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0"), Aspect = new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6"), Interlace = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd"), Stride = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
    internal static readonly Guid VideoProcessing = new("fb394f3d-ccf1-42ee-bbb3-f9b845d5681d"), RateControl = new("1c0608e9-370c-4710-8a58-cb6181c42423"), Quality = new("fcbf57a3-7ea5-4b0c-9644-69b40c39c391"), Gop = new("95f31b26-95a4-41aa-9303-246a7fc6eef1"), BFrames = new("8d390aac-dc5c-4200-b57f-814d04babab2");
    internal static readonly Guid MinimumAperture = new("d7388766-18fe-48c6-a177-ee894867c8c4"), GeometricAperture = new("66758743-7e5f-400d-980a-aa8596c85696");
    internal static (int Width, int Height) FrameExtent(IMFMediaType type)
    {
        type.GetUINT64(FrameSize, out var size);
        int width = checked((int)(size >> 32)), height = checked((int)(size & uint.MaxValue));
        if (width <= 0 || height <= 0 || width > 16016 || height > 16016 || (long)width * height > 40_600_000)
            throw new InvalidDataException($"Invalid video frame dimensions {width}x{height}.");
        return (width, height);
    }
    internal static (int Width, int Height) PresentationExtent(IMFMediaType type)
    {
        var frame = FrameExtent(type);
        var visible = Aperture(type, MinimumAperture) ?? Aperture(type, GeometricAperture) ?? new Rectangle(0, 0, frame.Width, frame.Height);
        if (visible.X < 0 || visible.Y < 0 || visible.Width <= 0 || visible.Height <= 0 || visible.Right > frame.Width || visible.Bottom > frame.Height)
            throw new InvalidDataException("Video presentation aperture lies outside its frame.");
        return (visible.Width, visible.Height);
    }
    internal static bool MatchesArchiveExtent(int width, int height, VisualArchive reference) =>
        (width == reference.Width || width == ((reference.Width + 1) & ~1)) &&
        (height == reference.Height || height == ((reference.Height + 1) & ~1));
    internal static Rectangle? Aperture(IMFMediaType type, Guid key)
    {
        int size;
        try { type.GetBlobSize(key, out size); }
        catch (COMException error) when ((uint)error.HResult == 0xC00D36E6) { return null; } // MF_E_ATTRIBUTENOTFOUND
        if (size != 16) throw new InvalidDataException("Invalid video display aperture size.");
        var bytes = new byte[size];
        type.GetBlob(key, bytes, size, out var written);
        if (written != 16 || BitConverter.ToUInt16(bytes, 0) != 0 || BitConverter.ToUInt16(bytes, 4) != 0)
            throw new InvalidDataException("Video display aperture has unsupported fractional offsets.");
        return new Rectangle(BitConverter.ToInt16(bytes, 2), BitConverter.ToInt16(bytes, 6), BitConverter.ToInt32(bytes, 8), BitConverter.ToInt32(bytes, 12));
    }
    internal static object DescribeType(IMFMediaType type)
    {
        var extent = FrameExtent(type);
        int? stride = null;
        try { type.GetUINT32(Stride, out var value); stride = value; } catch (COMException) { }
        return new { extent.Width, extent.Height, Stride = stride, Minimum = Aperture(type, MinimumAperture)?.ToString(), Geometric = Aperture(type, GeometricAperture)?.ToString() };
    }
    private static readonly Guid DisableFrc = new("2c0afa19-7a97-4d5a-9ee8-16d4fc518d8c");
    internal static string DisableFrameRateConversion(IMFSinkWriter writer, int stream)
    {
        var extended = (IVisualSinkWriterEx)writer;
        var observations = new List<string>();
        for (int index = 0; index < 16; index++)
        {
            var result = extended.GetTransformForStream(stream, index, out var category, out var transform);
            if (result < 0) { observations.Add($"end=0x{result:X8}"); break; }
            IMFAttributes? attributes = null;
            try
            {
                if (category == MediaFoundationTransformCategories.VideoProcessor || category == MediaFoundationTransformCategories.VideoEffect)
                {
                    transform.GetAttributes(out attributes);
                    // Without this the sink writer's color converter converts
                    // variable source times to the nominal 1 fps output rate.
                    // Set before BeginWriting: preserve every forced card sample.
                    attributes.SetUINT32(DisableFrc, 1);
                    attributes.GetUINT32(DisableFrc, out var disabled);
                    if (disabled != 1) throw new InvalidOperationException("The video processor could not preserve capture timestamps.");
                    observations.Add($"transform={index},category={category},frameRateConversion=disabled");
                }
                else observations.Add($"transform={index},category={category}");
            }
            finally { Release(attributes); Release(transform); }
        }
        return string.Join("; ", observations);
    }
    private static readonly object startupGate = new();
    private static bool started;
    internal static void Startup() { lock (startupGate) { if (!started) { MediaFoundationApi.Startup(); started = true; } } }
    internal static bool HasHardwareHevc()
    {
        IntPtr activations = IntPtr.Zero;
        int count = 0;
        try
        {
            MediaFoundationInterop.MFTEnumEx(MediaFoundationTransformCategories.VideoEncoder,
                _MFT_ENUM_FLAG.MFT_ENUM_FLAG_HARDWARE | _MFT_ENUM_FLAG.MFT_ENUM_FLAG_SORTANDFILTER, null!,
                new MFT_REGISTER_TYPE_INFO { guidMajorType = MediaTypes.MFMediaType_Video, guidSubtype = Hevc }, out activations, out count);
            if (count == 0) return false;
        }
        finally
        {
            for (int i = 0; i < count; i++) Marshal.Release(Marshal.ReadIntPtr(activations, i * IntPtr.Size));
            if (activations != IntPtr.Zero) Marshal.FreeCoTaskMem(activations);
        }
        activations = IntPtr.Zero; count = 0;
        try
        {
            MediaFoundationInterop.MFTEnumEx(MediaFoundationTransformCategories.VideoDecoder,
                _MFT_ENUM_FLAG.MFT_ENUM_FLAG_ALL | _MFT_ENUM_FLAG.MFT_ENUM_FLAG_SORTANDFILTER,
                new MFT_REGISTER_TYPE_INFO { guidMajorType = MediaTypes.MFMediaType_Video, guidSubtype = Hevc }, null!, out activations, out count);
            return count > 0;
        }
        finally
        {
            for (int i = 0; i < count; i++) Marshal.Release(Marshal.ReadIntPtr(activations, i * IntPtr.Size));
            if (activations != IntPtr.Zero) Marshal.FreeCoTaskMem(activations);
        }
    }
    internal static void Release(object? value) { if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value); }
    internal static IMFMediaType Type(Guid codec, int width, int height)
    {
        var type = MediaFoundationApi.CreateMediaType();
        try
        {
            type.SetGUID(MediaFoundationAttributes.MF_MT_MAJOR_TYPE, MediaTypes.MFMediaType_Video);
            type.SetGUID(MediaFoundationAttributes.MF_MT_SUBTYPE, codec);
            type.SetUINT64(FrameSize, ((long)width << 32) | (uint)height);
            type.SetUINT64(FrameRate, (1L << 32) | 1);
            type.SetUINT64(Aspect, (1L << 32) | 1);
            type.SetUINT32(Interlace, 2);
            return type;
        }
        catch { Release(type); throw; }
    }
}
