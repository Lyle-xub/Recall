using System.Buffers.Binary;
using System.Text.Json;
using Rewind;

internal static class CompactOcrRegionsTests
{
    public static void Run(Action<bool, string> assert)
    {
        var regions = Enumerable.Range(0, 300).Select(i => new TextRegion(
            $"中文小字 🧭 changed character {i}", (double)i / 731, 0.123456789123, 0.0312345678123, i == 0 ? -0d : .01)).ToList();
        var encoded = CompactOcrRegions.Encode(regions);
        var decoded = CompactOcrRegions.Decode(encoded);
        assert(encoded.StartsWith("br-regions1:"), "Repeated OCR regions use lossless compression");
        assert(encoded.Length < JsonSerializer.Serialize(regions).Length / 2, "Region compression meaningfully reduces repeated coordinate metadata");
        assert(decoded.SequenceEqual(regions), "Unicode text and region values round-trip exactly");
        assert(decoded.Zip(regions).All(pair => BitConverter.DoubleToInt64Bits(pair.First.X) == BitConverter.DoubleToInt64Bits(pair.Second.X)
            && BitConverter.DoubleToInt64Bits(pair.First.Y) == BitConverter.DoubleToInt64Bits(pair.Second.Y)
            && BitConverter.DoubleToInt64Bits(pair.First.Width) == BitConverter.DoubleToInt64Bits(pair.Second.Width)
            && BitConverter.DoubleToInt64Bits(pair.First.Height) == BitConverter.DoubleToInt64Bits(pair.Second.Height)), "All IEEE-754 coordinate bits are preserved, including negative zero");
        assert(CompactOcrRegions.Decode(JsonSerializer.Serialize(regions)).SequenceEqual(regions), "Legacy JSON regions remain readable");
        assert(CompactOcrRegions.Encode([]) == "[]" && CompactOcrRegions.Decode("[]").Count == 0, "Small payloads keep economical legacy JSON");

        void Reject(string payload, string message)
        {
            try { CompactOcrRegions.Decode(payload); }
            catch (InvalidDataException) { assert(true, message); return; }
            assert(false, message);
        }
        const string prefix = "br-regions1:";
        var bytes = Convert.FromBase64String(encoded[prefix.Length..]);
        Reject(prefix + "not-base64", "Invalid base64 is rejected");
        Reject(prefix + Convert.ToBase64String(bytes[..20]), "Truncated header is rejected");
        Reject(prefix + Convert.ToBase64String(bytes[..^1]), "Truncated compressed stream is rejected");
        var corrupt = (byte[])bytes.Clone(); corrupt[4] ^= 1;
        Reject(prefix + Convert.ToBase64String(corrupt), "Checksum damage cannot silently alter OCR");
        var oversized = (byte[])bytes.Clone(); BinaryPrimitives.WriteInt32LittleEndian(oversized, int.MaxValue);
        Reject(prefix + Convert.ToBase64String(oversized), "Declared size is bounded before allocating");
        Reject(prefix + Convert.ToBase64String(bytes.Concat(new byte[] { 0 }).ToArray()), "Trailing compressed data is rejected");
    }
}
