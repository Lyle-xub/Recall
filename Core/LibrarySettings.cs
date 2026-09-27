using System.Text.Json.Nodes;
namespace Rewind;

public static class LibrarySettings
{
    public static JsonObject Update(string root,string key,string value,bool mac)
    {
        var path=Path.Combine(root,"settings.json");
        var settings=File.Exists(path)?JsonNode.Parse(File.ReadAllText(path))!.AsObject():new JsonObject();
        string field;JsonNode replacement;
        switch(key)
        {
            case "capture-interval":
                if(!int.TryParse(value,out var interval) || interval<1 || interval>3600)throw new RecallException("usage","capture-interval must be 1–3600 seconds.");
                field=mac?"captureInterval":"CaptureInterval";replacement=JsonValue.Create(interval)!;break;
            case "retention-days":
                if(!int.TryParse(value,out var days) || days<0 || days>36500)throw new RecallException("usage","retention-days must be 0–36500 (0 keeps all records).");
                field=mac?"retentionDays":"RetentionDays";replacement=JsonValue.Create(days)!;break;
            case "system-audio":case "microphone":case "transcription-enabled":
                if(!bool.TryParse(value,out var enabled))throw new RecallException("usage","Use true or false.");
                field=key=="system-audio"?"SystemAudio":key=="microphone"?"Microphone":"TranscriptionEnabled";
                if(mac)field=char.ToLowerInvariant(field[0])+field[1..];replacement=JsonValue.Create(enabled)!;break;
            case "excluded-apps":
                try {var names=System.Text.Json.JsonSerializer.Deserialize<string[]>(value);if(names==null || names.Any(string.IsNullOrWhiteSpace))throw new System.Text.Json.JsonException();replacement=System.Text.Json.Nodes.JsonArray.Create(System.Text.Json.JsonSerializer.SerializeToElement(names))!;}
                catch(System.Text.Json.JsonException){throw new RecallException("usage","excluded-apps must be a JSON array of application identifiers; [] explicitly permits capture without application exclusions.");}
                field=mac?"excludedApps":"ExcludedApps";break;
            default:throw new RecallException("usage","Supported keys: capture-interval, retention-days, system-audio, microphone, transcription-enabled, excluded-apps. Use model endpoint options for model calls.");
        }
        foreach(var old in settings.Select(p=>p.Key).Where(k=>k.Equals(field,StringComparison.OrdinalIgnoreCase)).ToArray())settings.Remove(old);
        settings[field]=replacement;
        Wire.Atomic(path,settings);
        return settings;
    }
}
