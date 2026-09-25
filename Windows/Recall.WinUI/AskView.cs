namespace Recall;

internal sealed class AskView : Grid
{
    readonly AppRuntime runtime; readonly Action<MemoryFrame> open; readonly List<ChatMessage> history = []; readonly StackPanel messages = new() { Spacing = 20 }; readonly TextBox question = Design.Input("Ask about your memories", height: 50); readonly Button send; readonly ScrollViewer scroll; CancellationTokenSource? cancellation;
    public AskView(AppRuntime runtime, Action<MemoryFrame> open)
    {
        this.runtime = runtime;
        this.open = open;
        MaxWidth = 960;
        HorizontalAlignment = HorizontalAlignment.Center;
        RowDefinitions.Add(new()
        {
            Height = GridLength.Auto
        });
        RowDefinitions.Add(new()
        {
            Height = new(1, GridUnitType.Star)
        });
        RowDefinitions.Add(new()
        {
            Height = GridLength.Auto
        });
        Children.Add(Design.Stack(6, Design.Text("Ask Recall", 30, true), Design.Text("Answers grounded in your captured memories.", 14, color: Design.Muted)));
        scroll = Design.Scroll(messages);
        scroll.Margin = new(0, 24, 0, 22);
        Grid.SetRow(scroll, 1);
        Children.Add(scroll);
        var composer = new Grid { ColumnSpacing = 10 };
        composer.ColumnDefinitions.Add(new()
        {
            Width = new(1, GridUnitType.Star)
        });
        composer.ColumnDefinitions.Add(new()
        {
            Width = GridLength.Auto
        });
        composer.Children.Add(question);
        send = Design.Button("Ask", () => _ = Answer(), true);
        Grid.SetColumn(send, 1);
        composer.Children.Add(send);
        Grid.SetRow(composer, 2);
        Children.Add(composer);
        question.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { _ = Answer(); e.Handled = true; } };
        Unloaded += (_, _) => cancellation?.Cancel();
    }
    async Task Answer()
    {
        if (cancellation != null)
        {
            cancellation.Cancel();
            return;
        }
        var text = question.Text.Trim();
        if (text.Length == 0)
            return;
        question.Text = "";
        messages.Children.Add(Design.Card(Design.Text(text, 17, true), 22, 18));
        var answer = Design.Text("Searching your memories…", 16);
        answer.IsTextSelectionEnabled = true;
        var sources = new StackPanel { Spacing = 6 };
        messages.Children.Add(Design.Stack(14, answer, sources));
        send.Content = Design.Text("Stop", 14, true, Microsoft.UI.Colors.White);
        cancellation = new();
        var ct = cancellation.Token;
        string? pendingText = null;
        var outputTimer = DispatcherQueue.CreateTimer();
        outputTimer.Interval = TimeSpan.FromMilliseconds(60);
        outputTimer.Tick += (_, _) =>
        {
            if (Interlocked.Exchange(ref pendingText, null) is not { } value)
                return;
            var followEnd = scroll.ScrollableHeight - scroll.VerticalOffset < 64;
            answer.Text = value;
            if (followEnd)
                scroll.ChangeView(null, scroll.ScrollableHeight, null);
        };
        try
        {
            var records = await Task.Run(() => runtime.Store.Retrieve(text, previous: history.LastOrDefault(x => x.Role == "user")?.Text), ct);
            var profile = runtime.Settings.Chat;
            if (profile.IsBuiltin)
                records = records.Take(5).ToList();
            if (records.Count == 0)
            {
                answer.Text = "No relevant memories were found. Try an app name, a phrase you saw, or a date.";
                return;
            }
            var transcripts = await Task.Run(() => records.Select(x => x.SessionId).Where(x => x != null).Distinct().SelectMany(x => runtime.Store.Transcript(x!)).ToList(), ct);
            foreach (var pair in records.Select((frame, i) => (frame, i)))
            {
                var b = Design.Button($"[{pair.i + 1}] {pair.frame.AppName} · {pair.frame.Timestamp.ToLocalTime():MMM d HH:mm}", () => open(pair.frame));
                sources.Children.Add(b);
            }
            answer.Text = "Preparing answer…";
            outputTimer.Start();
            var result = await ModelClient.Answer(text, records, transcripts, history, profile, SecretStore.Read("chat"), ct, value => Interlocked.Exchange(ref pendingText, value));
            outputTimer.Stop();
            history.Add(new("user", text));
            history.Add(new("assistant", result, records));
            answer.Text = result;
        }
        catch (OperationCanceledException) { if (answer.Text == "Preparing answer…" || answer.Text == "Searching your memories…") answer.Text = "Stopped."; }
        catch (Exception ex) { answer.Text = ex.Message; }
        finally { outputTimer.Stop(); cancellation.Dispose(); cancellation = null; send.Content = Design.Text("Ask", 14, true, Microsoft.UI.Colors.White); scroll.ChangeView(null, scroll.ScrollableHeight, null); }
    }
}
