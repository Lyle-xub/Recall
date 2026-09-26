using Microsoft.UI.Xaml.Media.Imaging;
namespace Recall;

internal static class MemoryImages
{
    static readonly Dictionary<string, byte[]> cache = []; static readonly Queue<string> order = []; static long bytes; static readonly SemaphoreSlim gate = new(2, 2);
    // BitmapImage belongs to the UI thread. Reuse decoded thumbnails as well
    // as encoded bytes so navigation does not decode the same wall repeatedly.
    static readonly Dictionary<string, BitmapImage> decoded = [];
    static readonly Queue<string> decodedOrder = [];
    static long decodedBytes;
    public static async Task<BitmapImage> Load(MemoryStore store, string relative, int edge = 1800, CancellationToken cancellation = default)
    {
        var key = store.Root + "/" + relative + "/" + edge;
        cancellation.ThrowIfCancellationRequested();
        if (decoded.TryGetValue(key, out var ready)) return ready;
        await gate.WaitAsync(cancellation);
        try
        {
            if (decoded.TryGetValue(key, out ready)) return ready;
            byte[]? data;
            lock (cache)
                cache.TryGetValue(key, out data);
            if (data == null)
            {
                data ??= await Task.Run(() => ImageArchive.Display(store.Root, relative, edge), cancellation);
                lock (cache)
                {
                    if (!cache.ContainsKey(key))
                    {
                        cache[key] = data;
                        order.Enqueue(key);
                        bytes += data.Length;
                    }
                    while (bytes > 48_000_000 && order.Count > 1)
                    {
                        var old = order.Dequeue();
                        bytes -= cache[old].Length;
                        cache.Remove(old);
                    }
                }
            }
            cancellation.ThrowIfCancellationRequested();
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            using (var writer = new Windows.Storage.Streams.DataWriter(stream))
            {
                writer.WriteBytes(data);
                await writer.StoreAsync();
                writer.DetachStream();
            }
            stream.Seek(0);
            var source = new BitmapImage();
            await source.SetSourceAsync(stream);
            cancellation.ThrowIfCancellationRequested();
            if (decoded.TryGetValue(key, out ready)) return ready;
            decoded[key] = source; decodedOrder.Enqueue(key);
            decodedBytes += (long)source.PixelWidth * source.PixelHeight * 4;
            while (decodedBytes > 72_000_000 && decodedOrder.Count > 1)
            {
                var old = decodedOrder.Dequeue(); var bitmap = decoded[old];
                decodedBytes -= (long)bitmap.PixelWidth * bitmap.PixelHeight * 4;
                decoded.Remove(old);
            }
            return source;
        }
        finally { gate.Release(); }
    }
}
