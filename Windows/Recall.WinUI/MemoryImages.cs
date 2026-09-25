using Microsoft.UI.Xaml.Media.Imaging;
namespace Recall;

internal static class MemoryImages
{
    static readonly Dictionary<string, byte[]> cache = []; static readonly Queue<string> order = []; static long bytes; static readonly SemaphoreSlim gate = new(2, 2);
    public static async Task<BitmapImage> Load(MemoryStore store, string relative, int edge = 1800)
    {
        var key = relative + "/" + edge;
        byte[]? data;
        lock (cache)
            cache.TryGetValue(key, out data);
        if (data == null)
        {
            await gate.WaitAsync();
            try
            {
                data = await Task.Run(() => ImageArchive.Display(store.Root, relative, edge));
                lock (cache)
                {
                    if (!cache.ContainsKey(key))
                    {
                        cache[key] = data;
                        order.Enqueue(key);
                        bytes += data.Length;
                    } while (bytes > 48_000_000 && order.Count > 1)
                    {
                        var old = order.Dequeue();
                        bytes -= cache[old].Length;
                        cache.Remove(old);
                    }
                }
            }
            finally { gate.Release(); }
        }
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
        return source;
    }
}
