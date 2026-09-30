namespace Rewind;

public sealed record RecallEvidence(List<MemoryFrame> Sources, List<TranscriptLine> Transcripts, string Context);

public static class RecallSelection
{
    public static List<MemoryFrame> Overview(IEnumerable<MemoryFrame> frames, int limit)
    {
        if (limit <= 0) return [];
        var ordered = frames.OrderBy(f => f.Timestamp).ThenBy(f => f.Id)
            .DistinctBy(f => f.ProcessName + "|" + f.AppName + "|" + f.Title + "|" + f.Text).ToList();
        if (ordered.Count <= limit) return ordered;
        var selected = new List<MemoryFrame> { ordered[0], ordered[^1] };
        var ids = selected.Select(f => f.Id).ToHashSet();
        foreach (var app in ordered.Select(f => f.AppName).Distinct().Order())
        {
            if (selected.Count >= limit) break;
            if (selected.Any(f => f.AppName == app)) continue;
            var item = ordered.FirstOrDefault(f => f.AppName == app && !ids.Contains(f.Id));
            if (item != null) { selected.Add(item); ids.Add(item.Id); }
        }
        while (selected.Count < limit)
        {
            var item = ordered.Where(f => !ids.Contains(f.Id))
                .OrderByDescending(f => selected.Min(s => Math.Abs((s.Timestamp - f.Timestamp).TotalSeconds))).ThenBy(f => f.Timestamp).FirstOrDefault();
            if (item == null) break;
            selected.Add(item); ids.Add(item.Id);
        }
        return selected.OrderBy(f => f.Timestamp).Take(limit).ToList();
    }
}
