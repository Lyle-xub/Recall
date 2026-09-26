using System.Text.Json.Serialization;
namespace Rewind;

public record TextRegion(string Text, double X, double Y, double Width, double Height);
public record MemoryFrame
{
    public string Id { get; init; } = Guid.NewGuid().ToString();
    public DateTimeOffset Timestamp { get; init; } = DateTimeOffset.Now;
    public DateTimeOffset? EndTimestamp
    {
        get; init;
    }
    public string AppName { get; init; } = "Desktop";
    public string ProcessName { get; init; } = "";
    public string? ExecutablePath
    {
        get; init;
    }
    public string Title { get; init; } = "";
    public string ImagePath { get; init; } = "";
    public string? MeetingImagePath
    {
        get; init;
    }
    public string Text { get; init; } = "";
    public List<TextRegion> Regions { get; init; } = [];
    public List<TextRegion> MeetingRegions { get; init; } = [];
    public string? SessionId
    {
        get; init;
    }
    public bool Starred
    {
        get; init;
    }
    public bool Demo
    {
        get; init;
    }
    public DateTimeOffset? DeletedAt
    {
        get; init;
    }
    public string? PixelHash
    {
        get; init;
    }
    public double? ImageQuality
    {
        get; init;
    }
    public string? OcrId
    {
        get; init;
    }
    public RecognitionState TextState { get; init; } = RecognitionState.Complete;
    public string? TextError
    {
        get; init;
    }
    [JsonIgnore] public string TimeLabel => Timestamp.LocalDateTime.ToString("MMM d, yyyy h:mm tt");
}
public enum RecognitionState
{
    Pending, Working, Complete, Empty, Failed, Disabled
}
public record RecordingSession(string Id, DateTimeOffset StartedAt, DateTimeOffset? EndedAt, string VideoPath, bool HasAudio, string? SystemAudioPath = null, string? MicrophoneAudioPath = null, double SystemAudioOffset = 0, double MicrophoneAudioOffset = 0, RecognitionState SpeechState = RecognitionState.Pending, string? SpeechError = null, bool SeparateAudio = false);
public record TranscriptLine(string Id, string SessionId, DateTimeOffset Timestamp, string Speaker, string Text);
public record ModelProfile
{
    public string Provider { get; set; } = "Ollama";
    public bool IsBuiltin => Provider == "Built-in";
    public static ModelProfile BuiltinChat => new() { Provider = "Built-in", BaseUrl = "http://127.0.0.1/v1", Model = "Qwen3 · 1.7B" };
    public static ModelProfile BuiltinSpeech => new() { Provider = "Built-in", BaseUrl = "http://127.0.0.1/v1", Model = "Whisper · Base" };
    public string BaseUrl { get; set; } = "http://127.0.0.1:11434/v1";
    public string Model { get; set; } = "qwen3:8b";
    public bool IsLocal { get; set; } = true;
}
public record AppSettings
{
    public bool RhineLabMode { get; set; }
    public bool DarkAppearance { get; set; }
    public ModelProfile Chat { get; set; } = ModelProfile.BuiltinChat;
    public ModelProfile Speech { get; set; } = ModelProfile.BuiltinSpeech;
    public bool TranscriptionEnabled
    {
        get; set;
    }
    public bool SystemAudio
    {
        get; set;
    }
    public bool Microphone
    {
        get; set;
    }
    public int CaptureInterval { get; set; } = 3;
    public int RetentionDays { get; set; } = 30;
    public string[] ExcludedApps { get; set; } = ["1Password", "KeePass", "Bitwarden"];
    public string? DisplayName
    {
        get; set;
    }
    public bool LaunchAtLogin
    {
        get; set;
    }
    public bool RecordingRequested
    {
        get; set;
    }
    public bool ShowTaskbarIcon { get; set; } = true;
    public bool OnboardingComplete
    {
        get; set;
    }
    public bool LaunchFilmSeen
    {
        get; set;
    }
    public double ImageQuality { get; set; } = 0.5;
    public int VideoMaxEdge { get; set; } = 720;
    public int VideoBitrate { get; set; } = 100000;
    public ShortcutSettings Shortcuts { get; set; } = new();
}
public record ChatMessage(string Role, string Text, List<MemoryFrame>? Sources = null);
public record ShortcutBinding(uint Key, uint Modifiers)
{
    public string Label => string.Join(" + ", new[] { (Modifiers & 2) != 0 ? "Ctrl" : null, (Modifiers & 1) != 0 ? "Alt" : null, (Modifiers & 4) != 0 ? "Shift" : null, (Modifiers & 8) != 0 ? "Win" : null, Key switch { 32 => "Space", 27 => "Esc", 37 => "←", 39 => "→", 188 => ",", _ => ((char)Key).ToString() } }.Where(x => x != null));
    public bool IsValid => Key > 0 && Key < 256 && !new uint[] { 16, 17, 18, 91, 92 }.Contains(Key);
}
public record ShortcutSettings
{
    public ShortcutBinding Toggle { get; set; } = new(32, 2 | 4);
    public ShortcutBinding Alternate { get; set; } = new(32, 2 | 1);
    public ShortcutBinding Search { get; set; } = new(70, 2);
    public ShortcutBinding Settings { get; set; } = new(188, 2);
    public ShortcutBinding Back { get; set; } = new(27, 0);
    public ShortcutBinding Previous { get; set; } = new(37, 0);
    public ShortcutBinding Next { get; set; } = new(39, 0);
    public void Validate()
    {
        var all = new[] { Toggle, Alternate, Search, Settings, Back, Previous, Next };
        if (all.Any(x => !x.IsValid) || Toggle.Modifiers == 0 || Alternate.Modifiers == 0)
            throw new InvalidOperationException("Global shortcuts need at least one modifier and a regular key.");
        if (all.Distinct().Count() != all.Length)
            throw new InvalidOperationException("Choose a different shortcut for each action.");
    }
}
