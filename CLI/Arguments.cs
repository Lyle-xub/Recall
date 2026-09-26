using System.Globalization;
using Rewind;
namespace Recall.Cli;

public sealed class Arguments
{
    public readonly List<string> Words = [];
    public readonly Dictionary<string, string?> Options = [];
    static readonly HashSet<string> Flags = new("json help version yes dry-run starred trash demo ascending include-starred online builtin force save".Split(' '));
    public Arguments(string[] arguments)
    {
        bool literal = false;
        for (int i = 0; i < arguments.Length; i++)
        {
            var value = arguments[i];
            if (value == "--" && !literal) { literal = true; continue; }
            if (value == "-h") value = "--help";
            if (literal || !value.StartsWith('-')) { Words.Add(value); continue; }
            if (!value.StartsWith("--")) throw new RecallException("usage", "Unknown option: " + value);
            var pair = value[2..].Split('=', 2); var key = pair[0];
            if (Options.ContainsKey(key)) throw new RecallException("usage", "Duplicate option: --" + key);
            if (Flags.Contains(key))
            { if (pair.Length != 1) throw new RecallException("usage", "Flag --" + key + " takes no value."); Options[key] = null; }
            else if (pair.Length == 2) Options[key] = pair[1];
            else if (++i < arguments.Length && !arguments[i].StartsWith("--")) Options[key] = arguments[i];
            else throw new RecallException("usage", "Missing value for --" + key);
        }
    }
    public string? Get(string key) => Options.GetValueOrDefault(key);
    public bool Has(string key) => Options.ContainsKey(key);
    public string Require(string key) => Get(key) is { Length: > 0 } value ? value : throw new RecallException("usage", "--" + key + " is required.");
    public void Allow(string options, int words)
    {
        var allowed = new HashSet<string>((options + " data-dir json help").Split(' ', StringSplitOptions.RemoveEmptyEntries));
        foreach (var key in Options.Keys) if (!allowed.Contains(key)) throw new RecallException("usage", "Unknown option for this command: --" + key);
        if (Words.Count != words) throw new RecallException("usage", "Unexpected or missing arguments. Use --help for command syntax.");
    }
    public int Int(string key, int fallback, int min = 0, int max = 10000)
    {
        if (Get(key) is not { } value) return fallback;
        if (!int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var result) || result < min || result > max) throw new RecallException("usage", $"--{key} must be between {min} and {max}.");
        return result;
    }
    public string? Date(string key)
    {
        if (Get(key) is not { } text) return null;
        if (!DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)) throw new RecallException("usage", "Invalid ISO date for --" + key);
        return date.ToString("O");
    }
    public Dictionary<string, object?> Filter() => new()
    {
        ["query"] = Get("query") ?? "", ["app"] = Get("app"), ["since"] = Date("since"), ["until"] = Date("until"),
        ["starred"] = Has("starred"), ["trash"] = Has("trash"), ["demo"] = Has("demo"), ["ascending"] = Has("ascending"),
        ["limit"] = Int("limit", 100, 1), ["offset"] = Int("offset", 0, 0, int.MaxValue)
    };
    public const string Filters = "query app since until starred trash demo ascending limit offset";
}
