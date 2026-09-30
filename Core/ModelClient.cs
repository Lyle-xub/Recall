using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
namespace Rewind;

public static partial class ModelClient
{
    // Redirects are disabled so a localhost endpoint cannot forward private records elsewhere.
    internal static HttpClient client = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromMinutes(4) };
    public static Uri Endpoint(ModelProfile profile, string path)
    {
        if (!Uri.TryCreate(profile.BaseUrl.TrimEnd('/') + "/", UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
            throw new InvalidOperationException("Enter a valid HTTP or HTTPS API address.");
        if (profile.IsLocal && uri.Host is not ("localhost" or "127.0.0.1" or "[::1]" or "::1"))
            throw new InvalidOperationException("Local mode connects only to this computer. Use an online provider for a remote service.");
        if (!profile.IsLocal && uri.Scheme != "https")
            throw new InvalidOperationException("Online providers require HTTPS.");
        if (uri.AbsolutePath == "/")
            uri = new Uri(uri, "v1/");
        return new Uri(uri, path);
    }
    private static HttpRequestMessage Request(ModelProfile p, string path, string key, HttpMethod method)
    {
        var req = new HttpRequestMessage(method, Endpoint(p, path));
        if (key.Length > 0)
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        return req;
    }
    private static async Task<JsonDocument> Send(HttpRequestMessage req, CancellationToken ct)
    {
        using var response = await client.SendAsync(req, ct);
        var body = await response.Content.ReadAsStringAsync(ct);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Model service returned HTTP {(int)response.StatusCode}. Check the endpoint, model name, and key.");
        return JsonDocument.Parse(body);
    }
    public static async Task<string[]> Models(ModelProfile p, string key, CancellationToken ct = default)
    {
        if (p.IsBuiltin)
        {
            var local = await LocalInference.Chat(ct);
            return await Models(local.Profile, local.Key, ct);
        }
        using var req = Request(p, "models", key, HttpMethod.Get);
        using var doc = await Send(req, ct);
        return doc.RootElement.GetProperty("data").EnumerateArray().Select(x => x.GetProperty("id").GetString()!).ToArray();
    }
    public static async Task<string> Answer(string question, List<MemoryFrame> sources, List<TranscriptLine> transcripts, List<ChatMessage> history, ModelProfile profile, string key, CancellationToken ct, Action<string>? onDelta = null, string context = "")
    {
        if (profile.IsBuiltin)
        {
            var local = await LocalInference.Chat(ct);
            return await Answer(question, sources, transcripts, history, local.Profile, local.Key, ct, onDelta, context);
        }
        if (string.IsNullOrWhiteSpace(profile.Model))
            throw new InvalidOperationException("Choose a model in Settings.");
        var messages = RecallPrompt.Messages(question, sources, transcripts, history, context, profile.Provider == "Internal runtime");
        var overview=RecallPrompt.StructuredOverview(question,history,profile.Provider=="Internal runtime");
        string Final(string answer) => overview ? RecallPrompt.OverviewAnswer(answer,sources,question):answer;
        using var req = Request(profile, "chat/completions", key, HttpMethod.Post);
        var body = new Dictionary<string, object> { ["model"]=profile.Model,["messages"]=messages,["stream"]=onDelta != null,["max_tokens"]=1024 };
        if(profile.IsLocal) body["temperature"]=0.2;
        if(profile.Provider=="Internal runtime") body["chat_template_kwargs"]=new {enable_thinking=false};
        if(overview) body["response_format"]=RecallPrompt.OverviewFormat(sources);
        req.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        if (onDelta != null)
        {
            using var response = await client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentType?.MediaType == "text/event-stream")
            {
                using var reader = new StreamReader(await response.Content.ReadAsStreamAsync(ct));
                var answer = new StringBuilder();
                string? line;
                while ((line = await reader.ReadLineAsync(ct)) != null)
                {
                    if (!line.StartsWith("data:"))
                        continue;
                    var payload = line[5..].Trim();
                    if (payload == "[DONE]")
                        break;
                    using var chunk = JsonDocument.Parse(payload);
                    if (chunk.RootElement.TryGetProperty("choices", out var choices) && choices.GetArrayLength() > 0 && choices[0].TryGetProperty("delta", out var delta) && delta.TryGetProperty("content", out var text))
                    {
                        answer.Append(text.GetString());
                        if(!overview) onDelta(answer.ToString());
                    }
                }
                if (answer.Length == 0)
                    throw new InvalidOperationException("The model returned no answer.");
                var result=Final(answer.ToString());onDelta(result);return result;
            }
            using var fallback = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
            return Final(fallback.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString() ?? throw new InvalidOperationException("The model returned no answer."));
        }
        using var doc = await Send(req, ct);
        return Final(doc.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString() ?? throw new InvalidOperationException("The model returned no answer."));
    }
    public static async Task<List<TranscriptLine>> Transcribe(string audio, RecordingSession session, ModelProfile p, string key, CancellationToken ct = default)
    {
        if (p.IsBuiltin)
            return await LocalInference.Transcribe(audio, session, ct);
        if (new FileInfo(audio).Length > 24 * 1024 * 1024)
            throw new InvalidOperationException("The audio segment exceeds 24 MB.");
        using var req = Request(p, "audio/transcriptions", key, HttpMethod.Post);
        using var body = new MultipartFormDataContent();
        body.Add(new StringContent(p.Model), "model");
        body.Add(new StringContent("verbose_json"), "response_format");
        body.Add(new StringContent("segment"), "timestamp_granularities[]");
        var file = new StreamContent(File.OpenRead(audio));
        file.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        body.Add(file, "file", "recording.wav");
        req.Content = body;
        using var doc = await Send(req, ct);
        var root = doc.RootElement;
        if (root.TryGetProperty("segments", out var segments) && segments.GetArrayLength() > 0)
            return segments.EnumerateArray().Select(s => new TranscriptLine(Guid.NewGuid().ToString(), session.Id, session.StartedAt.AddSeconds(s.GetProperty("start").GetDouble()), s.TryGetProperty("speaker", out var speaker) ? speaker.ToString() : "Audio", s.GetProperty("text").GetString() ?? "")).ToList();
        return [new(Guid.NewGuid().ToString(), session.Id, session.StartedAt, "Audio", root.GetProperty("text").GetString() ?? "")];
    }
    [GeneratedRegex(@"https?://[^\s<>""']+", RegexOptions.IgnoreCase)] private static partial Regex LinkRegex();
    public static IEnumerable<Uri> Links(string text) => LinkRegex().Matches(text).Select(m => m.Value.TrimEnd('.', ',', ')', ';')).Where(x => Uri.TryCreate(x, UriKind.Absolute, out _)).Select(x => new Uri(x));
}
