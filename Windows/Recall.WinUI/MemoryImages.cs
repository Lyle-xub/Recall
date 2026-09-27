using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Buffers.Binary;
using System.Diagnostics;

namespace Recall;

internal static class MemoryImages
{
    const long EncodedLimit = 48_000_000;
    const long DecodedLimit = 72_000_000;
    static readonly object state = new();
    static readonly SemaphoreSlim fileGate = new(2, 2);
    static readonly SemaphoreSlim pipelineGate = new(4, 4);
    static readonly Dictionary<string, EncodedEntry> encoded = [];
    static readonly LinkedList<string> encodedOrder = [];
    static readonly Dictionary<string, DecodedEntry> decoded = [];
    static readonly LinkedList<string> decodedOrder = [];
    static readonly Dictionary<string, Pending> inFlight = [];
    static long encodedBytes, decodedBytes, encodedHits, decodedHits, sharedHits, completed, staleCanceled, failures;
    static long fileTicks, fileMaxTicks, fileCount, decodeTicks, decodeMaxTicks, decodeCount;
    static long uiQueueTicks, uiQueueMaxTicks, uiQueueCount, gateWaitTicks, gateWaitMaxTicks, gateWaitCount;
    static long pipelineWaitTicks, pipelineWaitMaxTicks, pipelineWaitCount;
    static object? lastFailure;

    sealed record EncodedEntry(byte[] Data, LinkedListNode<string> Node);
    sealed record DecodedEntry(BitmapImage Image, long Bytes, LinkedListNode<string> Node);
    sealed class Pending
    {
        internal readonly CancellationTokenSource Stop = new();
        internal readonly TaskCompletionSource<BitmapImage> Completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal int Waiters;
    }

    internal static object Diagnostics
    {
        get
        {
            lock (state) return new
            {
                encodedBytes, encodedCount = encoded.Count, encodedLimit = EncodedLimit,
                decodedBytes, decodedCount = decoded.Count, decodedLimit = DecodedLimit,
                inFlight = inFlight.Count, encodedHits, decodedHits, sharedHits,
                completed, staleCanceled, failures, lastFailure,
                maxConcurrentLoads = 4, maxConcurrentFiles = 2, maxConcurrentDecodes = 4,
                fileCount, fileMsTotal = Ms(fileTicks), fileMsMax = Ms(fileMaxTicks),
                decodeCount, decodeMsTotal = Ms(decodeTicks), decodeMsMax = Ms(decodeMaxTicks),
                uiQueueCount, uiQueueMsTotal = Ms(uiQueueTicks), uiQueueMsMax = Ms(uiQueueMaxTicks),
                gateWaitCount, gateWaitMsTotal = Ms(gateWaitTicks), gateWaitMsMax = Ms(gateWaitMaxTicks),
                pipelineWaitCount, pipelineWaitMsTotal = Ms(pipelineWaitTicks), pipelineWaitMsMax = Ms(pipelineWaitMaxTicks)
            };
        }
    }

    // The returned BitmapImage is created and initialized on the caller's UI
    // dispatcher. Identical requests on that dispatcher share one file read,
    // pack decode, PNG encode, and BitmapImage decode.
    public static Task<BitmapImage> Load(MemoryStore store, string relative, int edge = 1800, CancellationToken cancellation = default)
    {
        cancellation.ThrowIfCancellationRequested();
        var dispatcher = DispatcherQueue.GetForCurrentThread() ?? throw new InvalidOperationException("Images must be requested on the UI thread.");
        var dataKey = store.Root + "/" + relative + "/" + edge;
        var imageKey = Environment.CurrentManagedThreadId + "/" + dataKey;
        Pending pending;
        bool start = false;
        lock (state)
        {
            if (decoded.TryGetValue(imageKey, out var ready))
            {
                Promote(decodedOrder, ready.Node);
                decodedHits++;
                return Task.FromResult(ready.Image);
            }
            if (!inFlight.TryGetValue(imageKey, out pending!))
            {
                pending = new Pending();
                inFlight[imageKey] = pending;
                start = true;
            }
            else sharedHits++;
            pending.Waiters++;
        }
        if (start) _ = Produce(store, relative, edge, dataKey, imageKey, dispatcher, pending);
        return Await(pending, imageKey, cancellation);
    }

    static async Task<BitmapImage> Await(Pending pending, string key, CancellationToken cancellation)
    {
        try { return await pending.Completion.Task.WaitAsync(cancellation); }
        finally
        {
            var stop = false;
            lock (state)
            {
                pending.Waiters--;
                if (pending.Waiters == 0 && !pending.Completion.Task.IsCompleted)
                {
                    if (inFlight.TryGetValue(key, out var current) && ReferenceEquals(current, pending))
                        inFlight.Remove(key);
                    staleCanceled++;
                    stop = true;
                }
            }
            if (stop)
            {
                // Completion can dispose the CTS after we release state.
                // In that case the producer has already finished the work.
                try { pending.Stop.Cancel(); }
                catch (ObjectDisposedException) { }
            }
        }
    }

    static async Task Produce(MemoryStore store, string relative, int edge, string dataKey,
        string imageKey, DispatcherQueue dispatcher, Pending pending)
    {
        var token = pending.Stop.Token;
        var pipelineEntered = false;
        try
        {
            BitmapImage? already;
            lock (state) already = decoded.TryGetValue(imageKey, out var ready) ? ready.Image : null;
            if (already != null) { pending.Completion.TrySetResult(already); return; }

            // Limit the entire file-to-UI lifecycle, including encoded bytes
            // held while waiting for the asynchronous BitmapImage decoder.
            var pipelineWaitStarted = Stopwatch.GetTimestamp();
            await pipelineGate.WaitAsync(token).ConfigureAwait(false);
            pipelineEntered = true;
            Track(ref pipelineWaitTicks, ref pipelineWaitMaxTicks, ref pipelineWaitCount,
                Stopwatch.GetTimestamp() - pipelineWaitStarted);
            token.ThrowIfCancellationRequested();
            var data = FindEncoded(dataKey);
            if (data == null)
            {
                var waitStarted = Stopwatch.GetTimestamp();
                await fileGate.WaitAsync(token).ConfigureAwait(false);
                Track(ref gateWaitTicks, ref gateWaitMaxTicks, ref gateWaitCount, Stopwatch.GetTimestamp() - waitStarted);
                try
                {
                    // Another request can fill the encoded cache while this one waits.
                    data = FindEncoded(dataKey);
                    if (data == null)
                    {
                        data = await Task.Run(() =>
                        {
                            token.ThrowIfCancellationRequested();
                            var fileStarted = Stopwatch.GetTimestamp();
                            try
                            {
                                var result = ImageArchive.Display(store.Root, relative, edge);
                                token.ThrowIfCancellationRequested();
                                return result;
                            }
                            finally { Track(ref fileTicks, ref fileMaxTicks, ref fileCount, Stopwatch.GetTimestamp() - fileStarted); }
                        }, token).ConfigureAwait(false);
                        token.ThrowIfCancellationRequested();
                        KeepEncoded(dataKey, data);
                    }
                }
                finally { fileGate.Release(); }
            }
            token.ThrowIfCancellationRequested();
            var bitmap = await Decode(dispatcher, data, imageKey, token).ConfigureAwait(false);
            lock (state) completed++;
            pending.Completion.TrySetResult(bitmap);
        }
        catch (OperationCanceledException error) { pending.Completion.TrySetCanceled(error.CancellationToken); }
        catch (Exception error)
        {
            var message = string.IsNullOrEmpty(store.Root) ? error.Message :
                error.Message.Replace(store.Root, "<store>", StringComparison.OrdinalIgnoreCase);
            lock (state)
            {
                failures++;
                lastFailure = new { relative, type = error.GetType().Name,
                    message = message.Length <= 180 ? message : message[..180] };
            }
            pending.Completion.TrySetException(error);
        }
        finally
        {
            if (pipelineEntered) pipelineGate.Release();
            lock (state)
                if (inFlight.TryGetValue(imageKey, out var current) && ReferenceEquals(current, pending))
                    inFlight.Remove(imageKey);
            pending.Stop.Dispose();
        }
    }

    static byte[]? FindEncoded(string key)
    {
        lock (state)
        {
            if (!encoded.TryGetValue(key, out var cached)) return null;
            Promote(encodedOrder, cached.Node);
            encodedHits++;
            return cached.Data;
        }
    }

    static async Task<BitmapImage> Decode(DispatcherQueue dispatcher, byte[] data, string key, CancellationToken cancellation)
    {
        var decodeStarted = Stopwatch.GetTimestamp();
        try
        {
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            using (var writer = new Windows.Storage.Streams.DataWriter(stream))
            {
                writer.WriteBytes(data);
                await writer.StoreAsync();
                writer.DetachStream();
            }
            cancellation.ThrowIfCancellationRequested();
            stream.Seek(0);
            var (source, decoding) = await OnUi(dispatcher, () =>
            {
                var bitmap = new BitmapImage();
                return (bitmap, bitmap.SetSourceAsync(stream));
            }).ConfigureAwait(false);
            await decoding;
            cancellation.ThrowIfCancellationRequested();
            // Display always emits PNG. Its header gives the decoded budget
            // without reading BitmapImage properties off the UI thread, so
            // inserting the completed image needs no second UI dispatch.
            KeepDecoded(key, source, PngDecodedBytes(data));
            return source;
        }
        finally { Track(ref decodeTicks, ref decodeMaxTicks, ref decodeCount, Stopwatch.GetTimestamp() - decodeStarted); }
    }

    static Task<T> OnUi<T>(DispatcherQueue dispatcher, Func<T> action)
    {
        if (dispatcher.HasThreadAccess)
        {
            try { return Task.FromResult(action()); }
            catch (Exception error) { return Task.FromException<T>(error); }
        }
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var queuedAt = Stopwatch.GetTimestamp();
        if (!dispatcher.TryEnqueue(() =>
        {
            Track(ref uiQueueTicks, ref uiQueueMaxTicks, ref uiQueueCount, Stopwatch.GetTimestamp() - queuedAt);
            try { completion.TrySetResult(action()); }
            catch (Exception error) { completion.TrySetException(error); }
        })) completion.TrySetException(new InvalidOperationException("The image UI dispatcher is no longer available."));
        return completion.Task;
    }

    static double Ms(long ticks) => Math.Round(ticks * 1000d / Stopwatch.Frequency, 1);
    static void Track(ref long total, ref long maximum, ref long count, long elapsed)
    {
        lock (state)
        {
            total += elapsed;
            maximum = Math.Max(maximum, elapsed);
            count++;
        }
    }

    static void KeepEncoded(string key, byte[] data)
    {
        if (data.LongLength > EncodedLimit) return;
        lock (state)
        {
            if (encoded.ContainsKey(key)) return;
            var node = encodedOrder.AddLast(key);
            encoded[key] = new EncodedEntry(data, node);
            encodedBytes += data.LongLength;
            while (encodedBytes > EncodedLimit && encodedOrder.First is { } first)
            {
                encodedOrder.RemoveFirst();
                encodedBytes -= encoded[first.Value].Data.LongLength;
                encoded.Remove(first.Value);
            }
        }
    }

    static long PngDecodedBytes(byte[] data)
    {
        ReadOnlySpan<byte> signature = [137, 80, 78, 71, 13, 10, 26, 10];
        if (data.Length < 24 || !data.AsSpan(0, 8).SequenceEqual(signature) ||
            !data.AsSpan(12, 4).SequenceEqual("IHDR"u8)) return 0;
        var width = BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(16, 4));
        var height = BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(20, 4));
        return width > 0 && height > 0 ? (long)width * height * 4 : 0;
    }

    static void KeepDecoded(string key, BitmapImage image, long size)
    {
        if (size <= 0 || size > DecodedLimit) return;
        lock (state)
        {
            if (decoded.ContainsKey(key)) return;
            var node = decodedOrder.AddLast(key);
            decoded[key] = new DecodedEntry(image, size, node);
            decodedBytes += size;
            while (decodedBytes > DecodedLimit && decodedOrder.First is { } first)
            {
                decodedOrder.RemoveFirst();
                decodedBytes -= decoded[first.Value].Bytes;
                decoded.Remove(first.Value);
            }
        }
    }

    static void Promote(LinkedList<string> list, LinkedListNode<string> node)
    {
        list.Remove(node);
        list.AddLast(node);
    }
}
