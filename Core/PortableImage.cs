using System.Buffers.Binary;
using System.ComponentModel;
using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.Json;

namespace Rewind;

/// A bitmap borrowed from the library or decoded into a private temporary directory.
/// Disposing never modifies source media, including video and packed tile payloads.
public sealed class PortableImage : IDisposable
{
    public string Path { get; }
    private readonly string? temporaryDirectory;
    private PortableImage(string path, string? temporary = null) { Path = path; temporaryDirectory = temporary; }
    public void Dispose() { if (temporaryDirectory != null) Directory.Delete(temporaryDirectory, recursive: true); }
    public static bool IsArchive(string path) => System.IO.Path.GetExtension(path).ToLowerInvariant() is ".recallvideo" or ".recallframe" or ".recallvisual";

    public static Task<PortableImage> Open(string root, string relative, CancellationToken ct = default)
        => Decode(ArchivePaths.Owned(root, relative), System.IO.Path.GetFullPath(root), ct);

    /// Standalone references live in a library's frames directory. An explicit root
    /// may disambiguate deeper paths; it never changes the root of an import target.
    public static Task<PortableImage> OpenFile(string path, string? root = null, CancellationToken ct = default)
    {
        path = System.IO.Path.GetFullPath(path);
        if (!IsArchive(path)) return Decode(path, null, ct);
        if (root == null)
        {
            var parent = System.IO.Path.GetDirectoryName(path)!;
            if (!System.IO.Path.GetFileName(parent).Equals("frames", StringComparison.Ordinal))
                throw new RecallException("invalid_path", "An archive reference must be inside its library's frames directory; specify --data-dir for OCR on deeper paths.");
            root = System.IO.Path.GetDirectoryName(parent)!;
        }
        root = System.IO.Path.GetFullPath(root);
        var relative = System.IO.Path.GetRelativePath(root, path).Replace(System.IO.Path.DirectorySeparatorChar, '/');
        return Decode(ArchivePaths.Owned(root, relative), root, ct);
    }

    private static async Task<PortableImage> Decode(string source, string? root, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!File.Exists(source)) throw new RecallException("not_found", "The referenced image is missing.");
        if (!IsArchive(source)) return new(source);
        if (System.IO.Path.GetExtension(source).Equals(".recallvisual", StringComparison.OrdinalIgnoreCase))
            throw new RecallException("unsupported_media", "This older visual archive requires its native desktop decoder.");
        var temporary = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "recall-image-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(temporary, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        try
        {
            var output = System.IO.Path.Combine(temporary, "image.png");
            if (System.IO.Path.GetExtension(source).Equals(".recallvideo", StringComparison.OrdinalIgnoreCase))
            {
                var reference = VisualArchive.Read(source);
                var video = reference.Validate(root!);
                if (!File.Exists(video)) throw new RecallException("not_found", "The video backing this image is missing.");
                // Decode from the original timeline. Input seeking can silently land
                // on an adjacent/key frame; selecting the recorded PTS cannot do so.
                var pts = await ExactPresentationTimestamp(video, reference, ct);
                var filter = "select=eq(pts\\," + pts.ToString(CultureInfo.InvariantCulture) + ")";
                await Ffmpeg(["-noautorotate", "-copyts", "-i", video, "-map", "0:v:0", "-vf", filter, "-fps_mode", "passthrough", "-frames:v", "1", "-pix_fmt", "rgba", output], ct);
                if (!File.Exists(output)) throw new RecallException("unsupported_media", "The exact recorded video frame does not exist; no adjacent frame was substituted.");
                var size = PngSize(output);
                if (size != (reference.Width, reference.Height))
                {
                    // Native Windows encoders pad only the right/bottom edge to
                    // even dimensions. Existing Mac media may be unpadded.
                    if (size != ((reference.Width + 1) & ~1, (reference.Height + 1) & ~1))
                        throw new InvalidDataException("The decoded image dimensions do not match its archive reference.");
                    var cropped = System.IO.Path.Combine(temporary, "cropped.png");
                    await Ffmpeg(["-i", output, "-vf", $"crop={reference.Width}:{reference.Height}:0:0:exact=1", "-frames:v", "1", "-pix_fmt", "rgba", cropped], ct);
                    VerifyPng(cropped, reference.Width, reference.Height);
                    File.Move(cropped, output, overwrite: true);
                }
            }
            else
            {
                var manifest = ScreenManifest.Read(source);
                var canvas = System.IO.Path.Combine(temporary, "canvas.pam");
                var header = Encoding.ASCII.GetBytes($"P7\nWIDTH {manifest.Width}\nHEIGHT {manifest.Height}\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n");
                using var packs = File.Exists(ArchivePaths.Owned(root!, "frames/packs/catalog.sqlite")) ? new TilePackStore(root!) : null;
                var payloads = packs?.ReadTiles(manifest.Tiles.Select(t=>t.Path)) ?? manifest.Tiles.Select(t=>new TilePayload(t.Path,TilePackStore.ReadTile(root!,t.Path) ?? throw new RecallException("not_found", "A screenshot block is missing from both packed and loose storage.")));
                using (var destination = new FileStream(canvas, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
                {
                    destination.Write(header);
                    destination.SetLength(header.Length + (long)manifest.Width * manifest.Height * 4);
                    foreach (var (tile, payload) in manifest.Tiles.Zip(payloads))
                    {
                        ct.ThrowIfCancellationRequested();
                        var encoded = System.IO.Path.Combine(temporary, "tile" + System.IO.Path.GetExtension(tile.Path));
                        var decoded = System.IO.Path.Combine(temporary, "tile.pam");
                        await File.WriteAllBytesAsync(encoded, payload.Data, ct);
                        await Ffmpeg(["-i", encoded, "-frames:v", "1", "-pix_fmt", "rgba", "-c:v", "pam", decoded], ct);
                        using (var pixels = new FileStream(decoded, FileMode.Open, FileAccess.Read, FileShare.Read))
                        {
                            ReadPamHeader(pixels, tile.Width, tile.Height);
                            var row = new byte[tile.Width * 4];
                            for (var y = 0; y < tile.Height; y++)
                            {
                                ct.ThrowIfCancellationRequested();
                                pixels.ReadExactly(row);
                                destination.Position = header.Length + ((long)(tile.Y + y) * manifest.Width + tile.X) * 4;
                                destination.Write(row);
                            }
                        }
                        File.Delete(encoded); File.Delete(decoded);
                    }
                }
                await Ffmpeg(["-i", canvas, "-frames:v", "1", "-pix_fmt", "rgba", output], ct);
                VerifyPng(output, manifest.Width, manifest.Height);
            }
            ct.ThrowIfCancellationRequested();
            return new(output, temporary);
        }
        catch (Exception error)
        {
            Directory.Delete(temporary, recursive: true);
            if (error is Win32Exception) throw new RecallException("engine_missing", "Archive image decoding requires FFmpeg (and ffprobe for video). Install them or set RECALL_FFMPEG / RECALL_FFPROBE to their executables.");
            if (error is InvalidDataException or EndOfStreamException) throw new RecallException("unsupported_media", error.Message);
            throw;
        }
    }
    private static async Task<long> ExactPresentationTimestamp(string video, VisualArchive reference, CancellationToken ct)
    {
        var result = await ChildProcess.Run(Environment.GetEnvironmentVariable("RECALL_FFPROBE") ?? "ffprobe",
            ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=time_base", "-of", "json", video], null, ct, 30);
        if (result.ExitCode != 0) throw new RecallException("unsupported_media", "The archived video's timestamp scale could not be verified.");
        using var document = JsonDocument.Parse(result.Output);
        var scale = document.RootElement.GetProperty("streams")[0].GetProperty("time_base").GetString()!.Split('/');
        if (scale.Length != 2 || !long.TryParse(scale[0], NumberStyles.None, CultureInfo.InvariantCulture, out var numerator) || !long.TryParse(scale[1], NumberStyles.None, CultureInfo.InvariantCulture, out var denominator) || numerator <= 0 || denominator <= 0)
            throw new InvalidDataException("The archived video has an invalid timestamp scale.");
        // Match the native reader's checked conversion to 100 ns. Work with
        // rational integers: rounding pts*TB to a low manifest timescale could
        // wrongly accept a neighboring VFR sample, e.g. .3005 for .3000 seconds.
        var time = (BigInteger)reference.Ticks * 10_000_000 / reference.Timescale;
        var unit = (BigInteger)numerator * 10_000_000;
        var first = (time * denominator + unit - 1) / unit;
        var last = ((time + 1) * denominator + unit - 1) / unit - 1;
        if (first != last || first < 0 || first > 9_007_199_254_740_991L)
            throw new InvalidDataException("The exact recorded timestamp is not uniquely representable by this video.");
        return (long)first;
    }
    private static async Task Ffmpeg(string[] arguments, CancellationToken ct)
    {
        var result = await ChildProcess.Run(Environment.GetEnvironmentVariable("RECALL_FFMPEG") ?? "ffmpeg",
            new[] { "-v", "error", "-nostdin", "-threads", "1" }.Concat(arguments.Take(arguments.Length - 1)).Concat(new[] { "-threads", "1", "-y", arguments[^1] }), null, ct, 120);
        if (result.ExitCode != 0) throw new RecallException("unsupported_media", "FFmpeg could not decode the archived image; source media was preserved.");
    }
    internal static void VerifyPng(string path, int width, int height)
    {
        if (PngSize(path) != (width, height)) throw new InvalidDataException("The decoded image dimensions do not match its archive reference.");
    }
    private static (int Width, int Height) PngSize(string path)
    {
        using var stream = File.OpenRead(path);
        Span<byte> header = stackalloc byte[24]; stream.ReadExactly(header);
        ReadOnlySpan<byte> signature = [137, 80, 78, 71, 13, 10, 26, 10];
        if (!header[..8].SequenceEqual(signature) || !header.Slice(12, 4).SequenceEqual("IHDR"u8)) throw new InvalidDataException("The decoder did not produce a PNG image.");
        return (BinaryPrimitives.ReadInt32BigEndian(header[16..20]), BinaryPrimitives.ReadInt32BigEndian(header[20..24]));
    }
    private static void ReadPamHeader(FileStream stream, int width, int height)
    {
        var bytes = new List<byte>();
        while (bytes.Count < 4096)
        {
            var next = stream.ReadByte(); if (next < 0) break;
            bytes.Add((byte)next);
            if (next != '\n' || bytes.Count < 7 || Encoding.ASCII.GetString(bytes.TakeLast(7).ToArray()) != "ENDHDR\n") continue;
            var lines = Encoding.ASCII.GetString(bytes.ToArray()).Split('\n');
            if (lines[0] != "P7" || !lines.Contains($"WIDTH {width}") || !lines.Contains($"HEIGHT {height}") || !lines.Contains("DEPTH 4") || !lines.Contains("MAXVAL 255") || stream.Length - stream.Position != (long)width * height * 4)
                throw new InvalidDataException("A decoded screenshot block has unexpected dimensions or pixel format.");
            return;
        }
        throw new InvalidDataException("Invalid decoded screenshot block.");
    }
}
