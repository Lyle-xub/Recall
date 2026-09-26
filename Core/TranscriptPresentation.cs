using System.Text.RegularExpressions;
namespace Rewind;

public static class TranscriptPresentation
{
    static readonly HashSet<string> tracks = new(StringComparer.OrdinalIgnoreCase) { "Audio", "You", "Meeting", "System", "Microphone", "" };
    static string Normal(string text) => Regex.Replace(MemorySearch.Normalize(text), @"[^\p{L}\p{N}]+", " ").Trim();
    public static List<TranscriptLine> Visible(IEnumerable<TranscriptLine> source)
    {
        var result = new List<TranscriptLine>();
        foreach (var line in source.OrderBy(x => x.Timestamp))
        {
            if (string.IsNullOrWhiteSpace(line.Text) || Regex.IsMatch(line.Text.Trim(), @"^\[(BLANK_AUDIO|NO_SPEECH|SILENCE)\]$", RegexOptions.IgnoreCase))
                continue;
            var normalized = Normal(line.Text);
            var words = normalized.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (words.Length >= 5 && words.Length <= 240 && result.Any(x => x.Speaker != line.Speaker && Math.Abs((x.Timestamp - line.Timestamp).TotalSeconds) <= 18 && Normal(x.Text) == normalized))
                continue;
            result.Add(line);
        }
        return result;
    }
    public static bool HasDistinctSpeakers(IEnumerable<TranscriptLine> lines) => lines.Where(l => !tracks.Contains(l.Speaker)).Select(l => l.Speaker).Distinct().Count() > 1;
}
