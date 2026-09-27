using System.Buffers.Binary;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Rewind;

/// <summary>Lossless region storage; old JSON remains readable and search text stays in FTS.</summary>
internal static class CompactOcrRegions
{
    const string Prefix = "br-regions1:";
    const int Limit = 16 * 1024 * 1024;
    const int CountLimit = 100_000;
    const int HeaderSize = 4 + 32;
    static readonly UTF8Encoding Utf8 = new(false, true);

    public static string Encode(List<TextRegion> regions)
    {
        var json = JsonSerializer.Serialize(regions);
        if (regions.Count > CountLimit) throw Invalid("Too many text regions.");
        using var raw = new MemoryStream();
        using (var writer = new BinaryWriter(raw, Utf8, leaveOpen: true))
        {
            writer.Write(regions.Count);
            foreach (var region in regions)
            {
                if (region is null || region.Text is null) throw Invalid("Invalid text region.");
                var length = Utf8.GetByteCount(region.Text);
                if (raw.Length + 4L + length + 32 > Limit) throw Invalid("Text regions are too large.");
                writer.Write(length);
                writer.Write(Utf8.GetBytes(region.Text));
                writer.Write(BitConverter.DoubleToInt64Bits(region.X));
                writer.Write(BitConverter.DoubleToInt64Bits(region.Y));
                writer.Write(BitConverter.DoubleToInt64Bits(region.Width));
                writer.Write(BitConverter.DoubleToInt64Bits(region.Height));
            }
        }
        var source = raw.ToArray();
        using var encoded = new MemoryStream();
        Span<byte> lengthBytes = stackalloc byte[4];
        BinaryPrimitives.WriteInt32LittleEndian(lengthBytes, source.Length);
        encoded.Write(lengthBytes);
        encoded.Write(SHA256.HashData(source));
        using (var compressor = new BrotliStream(encoded, CompressionLevel.Fastest, leaveOpen: true))
            compressor.Write(source);
        var result = Prefix + Convert.ToBase64String(encoded.ToArray());
        return result.Length < Encoding.UTF8.GetByteCount(json) ? result : json;
    }

    public static List<TextRegion> Decode(string value)
    {
        if (!value.StartsWith(Prefix, StringComparison.Ordinal))
            return JsonSerializer.Deserialize<List<TextRegion>>(value) ?? [];
        if (value.Length > Prefix.Length + ((Limit + HeaderSize + 4096L) * 4 + 2) / 3)
            throw Invalid("Encoded text regions are too large.");
        try
        {
            var encoded = Convert.FromBase64String(value[Prefix.Length..]);
            if (encoded.Length <= HeaderSize) throw Invalid("Incomplete text regions.");
            var length = BinaryPrimitives.ReadInt32LittleEndian(encoded);
            if (length < 4 || length > Limit) throw Invalid("Invalid text region size.");
            var source = new byte[length];
            using var decoder = new BrotliDecoder();
            var status = decoder.Decompress(encoded.AsSpan(HeaderSize), source, out var consumed, out var written);
            if (status != System.Buffers.OperationStatus.Done || written != length || consumed != encoded.Length - HeaderSize ||
                !CryptographicOperations.FixedTimeEquals(encoded.AsSpan(4, 32), SHA256.HashData(source)))
                throw Invalid("Text region integrity check failed.");
            using var reader = new BinaryReader(new MemoryStream(source, writable: false), Utf8);
            var count = reader.ReadInt32();
            if (count < 0 || count > CountLimit || (long)count * 36 > source.Length - 4)
                throw Invalid("Invalid text region count.");
            var regions = new List<TextRegion>(count);
            for (var index = 0; index < count; index++)
            {
                var textLength = reader.ReadInt32();
                if (textLength < 0 || textLength > reader.BaseStream.Length - reader.BaseStream.Position - 32)
                    throw Invalid("Invalid text region text length.");
                var text = Utf8.GetString(reader.ReadBytes(textLength));
                var x = BitConverter.Int64BitsToDouble(reader.ReadInt64());
                var y = BitConverter.Int64BitsToDouble(reader.ReadInt64());
                var width = BitConverter.Int64BitsToDouble(reader.ReadInt64());
                var height = BitConverter.Int64BitsToDouble(reader.ReadInt64());
                regions.Add(new(text, x, y, width, height));
            }
            if (reader.BaseStream.Position != reader.BaseStream.Length) throw Invalid("Unexpected trailing text regions.");
            return regions;
        }
        catch (Exception error) when (error is FormatException or EndOfStreamException or DecoderFallbackException)
        {
            throw Invalid("Invalid compressed text regions.", error);
        }
    }

    static InvalidDataException Invalid(string message, Exception? inner = null) => new(message, inner);
}
