namespace Rewind;

public sealed partial class MemoryStore
{
    private string ImageReferencePredicate()
    {
        var collation = OperatingSystem.IsWindows() ? " COLLATE NOCASE" : "";
        return "(json_extract(f.json,'$.ImagePath')=$p0" + collation + " OR json_extract(f.json,'$.MeetingImagePath')=$p0" + collation + ")";
    }
    private bool OptimizableImage(string path, IReadOnlyCollection<MemoryFrame> references)
    {
        if (string.IsNullOrEmpty(path) || references.Count == 0 || TilePackStore.IsTilePath(path) ||
            path.EndsWith(".ocr.png", StringComparison.OrdinalIgnoreCase) ||
            path.EndsWith(".recallframe", StringComparison.OrdinalIgnoreCase) ||
            path.EndsWith(".recallvideo", StringComparison.OrdinalIgnoreCase)) return false;
        if (references.Any(frame => frame.TextState is not (RecognitionState.Complete or RecognitionState.Empty) ||
            frame.VisualTicks != null || frame.VisualWidth != null || frame.VisualHeight != null || frame.VisualSampleVerified ||
            frame.ImageQuality is <= .5)) return false;
        foreach (var id in references.Select(frame => frame.SessionId).Where(id => id != null).Distinct())
            if (Session(id!) is { } session && (session.UnifiedVisualArchive || session.EndedAt == null)) return false;
        return true;
    }
    /// <summary>Every current user of a source image must be safe to recompress, including meeting-image references.</summary>
    public bool CanOptimizeImage(string source)
    {
        lock (gate)
        {
            var references = Rows<MemoryFrame>("SELECT f.json FROM frames f WHERE " + ImageReferencePredicate(), source);
            return OptimizableImage(source, references);
        }
    }
    /// <summary>
    /// Recheck eligibility after encoding, atomically with metadata publication.
    /// The caller must decode-verify and flush a unique target before calling;
    /// false leaves its candidate unreferenced for the caller to remove.
    /// A null target records that recompression provided no space saving.
    /// </summary>
    public bool TryCommitImageOptimization(string source, string? target, double quality = .5)
    {
        lock (mediaGate) lock (gate)
        {
            var references = ReadFrames(SelectFrame + "WHERE " + ImageReferencePredicate(), source);
            if (!OptimizableImage(source, references)) return false;
            var original = ArchivePaths.Owned(Root, source);
            if (!File.Exists(original)) return false;
            if (target != null)
            {
                if (ArchivePaths.MediaComparer.Equals(source, target)) throw new ArgumentException("An optimization candidate must have its own path.", nameof(target));
                var candidate = ArchivePaths.Owned(Root, target);
                if (!File.Exists(candidate) || new FileInfo(candidate).Length == 0) throw new InvalidDataException("The verified optimization candidate is missing.");
            }
            Execute("BEGIN IMMEDIATE");
            try
            {
                foreach (var frame in references)
                    Save(frame with
                    {
                        ImagePath = target != null && ArchivePaths.MediaComparer.Equals(frame.ImagePath, source) ? target : frame.ImagePath,
                        MeetingImagePath = target != null && frame.MeetingImagePath != null && ArchivePaths.MediaComparer.Equals(frame.MeetingImagePath, source) ? target : frame.MeetingImagePath,
                        ImageQuality = quality
                    });
                Execute("COMMIT");
            }
            catch { Execute("ROLLBACK"); throw; }
            // Recognition/Retry/Save use gate as well: none can add an unsafe
            // reference between the eligibility check and this source retirement.
            if (target != null && !ReferencesImage(source)) File.Delete(original);
            return true;
        }
    }
}
