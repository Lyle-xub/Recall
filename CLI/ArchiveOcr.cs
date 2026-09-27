using Rewind;

namespace Recall.Cli;

internal static class ArchiveOcr
{
    internal static async Task Recognize(MemoryStore store, MemoryFrame frame, string language, CancellationToken ct)
    {
        using var main = await PortableImage.Open(store.Root, frame.ImagePath, ct);
        var result = await OcrEngine.Recognize(main.Path, language, ct);
        List<TextRegion>? meetingRegions = null;
        var text = result.Text;
        if (!string.IsNullOrEmpty(frame.MeetingImagePath))
        {
            using var meeting = await PortableImage.Open(store.Root, frame.MeetingImagePath, ct);
            var recognized = await OcrEngine.Recognize(meeting.Path, language, ct);
            meetingRegions = recognized.Regions;
            if (!string.IsNullOrWhiteSpace(recognized.Text)) text = string.Join("\n", new[] { text, recognized.Text }.Where(s => !string.IsNullOrWhiteSpace(s)));
        }
        ct.ThrowIfCancellationRequested();
        store.Recognized(frame.Id, text, result.Regions, meetingRegions);
    }
}
