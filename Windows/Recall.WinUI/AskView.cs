using System.Runtime.CompilerServices;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Markup;

namespace Recall;

internal sealed class AskView : Grid
{
    sealed class Conversation
    {
        public readonly List<ChatMessage> Turns = [];
        public readonly List<ChatMessage> History = [];
    }

    static readonly ConditionalWeakTable<AppRuntime, Conversation> conversations = new();
    readonly AppRuntime runtime;
    readonly Action<MemoryFrame> open;
    readonly Func<(string? AppFilter, DateTimeOffset? Since)> scope;
    readonly Action clearScope;
    readonly Conversation conversation;
    readonly Grid conversationHost = new();
    readonly StackPanel messages = new() { Spacing = 16 };
    readonly TextBox question = new()
    {
        PlaceholderText = "Ask about your memories…", FontFamily = Design.BodyFont,
        FontSize = 16, Foreground = Design.Brush(Design.Ink),
        PlaceholderForeground = Design.Brush(Design.Muted),
        Background = Design.Brush(Microsoft.UI.Colors.Transparent),
        BorderBrush = Design.Brush(Microsoft.UI.Colors.Transparent),
        BorderThickness = new(0), Padding = new(0, 12, 0, 12),
        UseSystemFocusVisuals = false,
        Template = (ControlTemplate)XamlReader.Load("""
            <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="TextBox">
              <Grid Background="Transparent">
                <ScrollViewer x:Name="ContentElement" Background="Transparent" Foreground="{TemplateBinding Foreground}" Padding="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden" IsTabStop="False" ZoomMode="Disabled" />
                <TextBlock x:Name="PlaceholderTextContentPresenter" Text="{TemplateBinding PlaceholderText}" Foreground="{TemplateBinding PlaceholderForeground}" Padding="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" IsHitTestVisible="False" />
              </Grid>
            </ControlTemplate>
            """)
    };
    readonly Button send, model, scopeClear;
    readonly TextBlock scopeLabel = Design.Text("", 11, color: Design.Muted);
    readonly TextBlock privacy = Design.Text("", 10, color: Design.Muted);
    readonly TextBlock errorText = Design.Text("", 12);
    readonly Grid errorPanel = new() { ColumnSpacing = 10 };
    readonly ScrollViewer scroll;
    EventHandler<object>? pendingBottomScroll;
    CancellationTokenSource? cancellation;
    int revision;
    string? lastQuestion;

    internal object Diagnostics => new
    {
        width = ActualWidth, height = ActualHeight, contentWidth = conversationHost.ActualWidth,
        empty = conversation.Turns.Count == 0 && cancellation == null,
        messages = conversation.Turns.Count, asking = cancellation != null,
        canSend = !string.IsNullOrWhiteSpace(question.Text), scope = scopeLabel.Text,
        model = runtime.Settings.Chat.Model, modelButton = model.ActualWidth,
        composerWidth = question.ActualWidth, errorVisible = errorPanel.Visibility == Visibility.Visible
    };

    public AskView(AppRuntime runtime, Action<MemoryFrame> open,
        Func<(string? AppFilter, DateTimeOffset? Since)> scope, Action clearScope, Action openModels)
    {
        this.runtime = runtime; this.open = open; this.scope = scope; this.clearScope = clearScope;
        conversation = conversations.GetValue(runtime, _ => new Conversation());
        MaxWidth = 1050; HorizontalAlignment = HorizontalAlignment.Stretch; Padding = new(24);
        Background = Design.Brush(Design.Dark ? Color.FromArgb(45, 80, 86, 98) : Color.FromArgb(41, 255, 255, 255));
        Design.Rounded(this, 28);
        for (var i = 0; i < 6; i++) RowDefinitions.Add(new() { Height = i == 2 ? new(1, GridUnitType.Star) : GridLength.Auto });

        var heading = new Grid { ColumnSpacing = 12 };
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        heading.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var sparkle = Design.Symbol("\uE945", 22, Design.Blue);
        sparkle.VerticalAlignment = VerticalAlignment.Center;
        heading.Children.Add(sparkle);
        var title = Design.Text("Ask Recall", 21, true); Grid.SetColumn(title, 1); heading.Children.Add(title);
        model = Design.Button("", openModels); model.MinHeight = 40; model.MaxWidth = 220; model.Padding = new(12, 7, 12, 7);
        Grid.SetColumn(model, 2); heading.Children.Add(model);
        var fresh = Design.Icon("\uE70F", "New conversation", NewConversation, 40); fresh.Padding = new(0);
        Grid.SetColumn(fresh, 3); heading.Children.Add(fresh);
        Children.Add(heading);

        var scopeRow = new Grid { Margin = new(0, 12, 0, 0), ColumnSpacing = 8 };
        scopeRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        scopeRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        scopeRow.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        scopeRow.Children.Add(scopeLabel);
        scopeClear = new Button { Content = "Clear scope", FontSize = 11, FontFamily = Design.SmallFont, Foreground = Design.Brush(Design.Blue), Background = Design.Brush(Microsoft.UI.Colors.Transparent), BorderThickness = new(0), Padding = new(2, 0, 2, 0), MinHeight = 24 };
        scopeClear.Click += (_, _) => { clearScope(); RefreshScope(); };
        Grid.SetColumn(scopeClear, 1); scopeRow.Children.Add(scopeClear);
        Grid.SetRow(scopeRow, 1); Children.Add(scopeRow);

        scroll = Design.Scroll(messages); scroll.Margin = new(0, 16, 0, 12);
        conversationHost.Children.Add(scroll); Grid.SetRow(conversationHost, 2); Children.Add(conversationHost);

        errorPanel.Visibility = Visibility.Collapsed; errorPanel.Margin = new(0, 0, 0, 12); errorPanel.Padding = new(14);
        errorPanel.Background = Design.Brush(Design.Dark ? Color.FromArgb(145, 82, 86, 96) : Color.FromArgb(166, 255, 255, 255));
        Design.Rounded(errorPanel, 14);
        errorPanel.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        errorPanel.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        errorPanel.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        errorPanel.Children.Add(new FontIcon { Glyph = "\uE783", FontFamily = new("Segoe Fluent Icons"), FontSize = 16, Foreground = Design.Brush(Color.FromArgb(255, 207, 132, 52)) });
        errorText.IsTextSelectionEnabled = true; Grid.SetColumn(errorText, 1); errorPanel.Children.Add(errorText);
        var retry = new Button { Content = "Retry", FontSize = 12, FontFamily = Design.BodyFont, MinHeight = 28 };
        retry.Click += (_, _) => { if (lastQuestion != null) { question.Text = lastQuestion; _ = Answer(); } };
        Grid.SetColumn(retry, 2); errorPanel.Children.Add(retry); Grid.SetRow(errorPanel, 3); Children.Add(errorPanel);

        var composer = new Grid { ColumnSpacing = 12, Padding = new(12), Margin = new(0, 0, 0, 8) };
        composer.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        composer.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        composer.Background = Design.Brush(Design.Dark ? Color.FromArgb(170, 70, 75, 85) : Color.FromArgb(204, 255, 255, 255));
        Design.Rounded(composer, 24);
        question.AcceptsReturn = true; question.TextWrapping = TextWrapping.Wrap; question.MinHeight = 46; question.Height = double.NaN; question.MaxHeight = 120;
        question.BorderThickness = new(0); question.VerticalAlignment = VerticalAlignment.Bottom;
        question.TextChanged += (_, _) => UpdateSend();
        question.KeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Enter) return;
            var shift = (InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0;
            if (shift) return;
            e.Handled = true; _ = Answer();
        };
        composer.Children.Add(question);
        send = new Button { Width = 46, Height = 46, CornerRadius = new(23), BorderThickness = new(0), Padding = new(0), Template = (ControlTemplate)XamlReader.Load("""
            <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
              <Border Background="{TemplateBinding Background}" CornerRadius="{TemplateBinding CornerRadius}">
                <ContentPresenter Content="{TemplateBinding Content}" HorizontalAlignment="Center" VerticalAlignment="Center" />
              </Border>
            </ControlTemplate>
            """) };
        send.Click += (_, _) => _ = Answer(); Grid.SetColumn(send, 1); composer.Children.Add(send);
        Grid.SetRow(composer, 4); Children.Add(composer);
        Grid.SetRow(privacy, 5); Children.Add(privacy);
        RefreshModel(); RefreshScope(); RenderConversation(); UpdateSend();
        Loaded += (_, _) => question.Focus(FocusState.Programmatic);
        Unloaded += (_, _) =>
        {
            revision++;
            if (pendingBottomScroll != null) { scroll.LayoutUpdated -= pendingBottomScroll; pendingBottomScroll = null; }
            var previous = cancellation;
            cancellation = null;
            previous?.Cancel();
        };
    }

    // Visual-parity sessions call this with their own synthetic fixture frames.
    // It exercises the conversation, source-card and overflow layouts offline.
    internal void ValidationConversation(IReadOnlyList<MemoryFrame> sources)
    {
        revision++;
        var previous = cancellation;
        cancellation = null;
        previous?.Cancel();
        conversation.Turns.Clear(); conversation.History.Clear();
        conversation.Turns.Add(new("user", "What happened in the interface study?"));
        var paragraph = "The interface study compared the captured layouts across several apps. The source cards below return to the exact screens used for this summary. ";
        conversation.Turns.Add(new("assistant", string.Concat(Enumerable.Repeat(paragraph, 12)) + "See [1], [2], and [3] for the recorded examples.", sources.Take(3).ToList()));
        errorPanel.Visibility = Visibility.Collapsed;
        RenderConversation(); UpdateSend();
    }

    void RefreshModel()
    {
        var profile = runtime.Settings.Chat;
        var label = string.IsNullOrWhiteSpace(profile.Model) ? "Choose a model" : profile.Model;
        var icon = new FontIcon { Glyph = profile.IsLocal ? "\uE770" : "\uE753", FontFamily = new("Segoe Fluent Icons"), FontSize = 14 };
        var text = Design.Text(label, 12); text.MaxWidth = 170; text.MaxLines = 1; text.TextTrimming = TextTrimming.CharacterEllipsis;
        model.Content = Design.Row(7, icon, text);
        AutomationProperties.SetName(model, "Choose model: " + label);
        privacy.Text = profile.IsLocal ? "♢  Local model · Memory text stays on this PC" : "☁  Online model · Relevant memory text is sent to your chosen provider";
    }

    void RefreshScope()
    {
        var (app, since) = scope();
        scopeLabel.Text = "☷  " + (app ?? "All apps") + " · " + (since is { } date ? "Since " + date.ToLocalTime().ToString("MMM d, yyyy") : "All recorded history");
        scopeClear.Visibility = app != null || since != null ? Visibility.Visible : Visibility.Collapsed;
    }

    internal void NewConversation()
    {
        revision++;
        var previous = cancellation;
        cancellation = null;
        previous?.Cancel();
        conversation.Turns.Clear(); conversation.History.Clear();
        lastQuestion = null; errorPanel.Visibility = Visibility.Collapsed; question.Text = "";
        RenderConversation(); UpdateSend(); question.Focus(FocusState.Programmatic);
    }

    void RenderConversation()
    {
        messages.Children.Clear();
        conversationHost.Children.Clear();
        if (conversation.Turns.Count == 0 && cancellation == null)
        {
            var empty = Design.Stack(15); empty.HorizontalAlignment = HorizontalAlignment.Center; empty.VerticalAlignment = VerticalAlignment.Center;
            var emptySparkle = Design.Symbol("\uE945", 34, Design.Blue);
            emptySparkle.HorizontalAlignment = HorizontalAlignment.Center;
            emptySparkle.VerticalAlignment = VerticalAlignment.Center;
            empty.Children.Add(new Border { Width = 78, Height = 78, CornerRadius = new(25), Background = Design.Brush(Design.Dark ? Color.FromArgb(105, 130, 150, 190) : Color.FromArgb(140, 255, 255, 255)), Child = emptySparkle });
            var heading = Design.Text("Ask your memory.", 28); heading.HorizontalAlignment = HorizontalAlignment.Center; empty.Children.Add(heading);
            var description = Design.Text("Answers grounded in your recorded screens and conversations,\nwith sources you can return to.", 14, color: Design.Muted);
            description.TextAlignment = TextAlignment.Center; empty.Children.Add(description);
            conversationHost.Children.Add(empty);
        }
        else
        {
            conversationHost.Children.Add(scroll);
            foreach (var turn in conversation.Turns) messages.Children.Add(Message(turn.Role, turn.Text, turn.Sources));
            ScrollToEnd();
        }
    }

    Border Message(string role, string text, List<MemoryFrame>? sources = null)
    {
        var body = Design.Stack(12);
        var header = new Grid(); header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.Children.Add(Design.Text(role == "user" ? "You" : "Recall", 11, true, Design.Muted));
        if (role != "user" && !string.IsNullOrEmpty(text))
        {
            var copy = new Button { Content = new FontIcon { Glyph = "\uE8C8", FontFamily = new("Segoe Fluent Icons"), FontSize = 14 }, Width = 32, Height = 32, Padding = new(0), Background = Design.Brush(Microsoft.UI.Colors.Transparent), BorderThickness = new(0) };
            copy.Click += (_, _) => FrameSurface.ClipboardText(text);
            AutomationProperties.SetName(copy, "Copy answer"); Grid.SetColumn(copy, 1); header.Children.Add(copy);
        }
        body.Children.Add(header);
        var answer = Design.Text(text, 15);
        answer.IsTextSelectionEnabled = true;
        answer.LineHeight = 22;
        answer.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        body.Children.Add(answer);
        if (sources is { Count: > 0 })
        {
            body.Children.Add(Design.Text($"{sources.Count} sources", 10, true, Design.Muted));
            var cards = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            foreach (var (source, index) in sources.Select((frame, i) => (frame, i)))
            {
                var card = new Grid { Width = 235, ColumnSpacing = 9, Padding = new(11) };
                card.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); card.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
                card.Children.Add(AppIcons.View(AppIcons.Identity(source), 23));
                var label = Design.Stack(4);
                var title = Design.Text($"[{index + 1}] {(string.IsNullOrEmpty(source.Title) ? source.AppName : source.Title)}", 11, true);
                title.MaxLines = 1; title.TextTrimming = TextTrimming.CharacterEllipsis; label.Children.Add(title);
                label.Children.Add(Design.Text(source.Timestamp.ToLocalTime().ToString("MMM d, HH:mm"), 10, color: Design.Muted));
                Grid.SetColumn(label, 1); card.Children.Add(label);
                var button = new Button { Content = card, Padding = new(0), CornerRadius = new(13), Background = Design.Brush(Design.Dark ? Color.FromArgb(115, 100, 105, 115) : Color.FromArgb(166, 255, 255, 255)), BorderThickness = new(0) };
                button.Click += (_, _) => open(source);
                AutomationProperties.SetName(button, $"Open source {index + 1} in the timeline"); cards.Children.Add(button);
            }
            body.Children.Add(new ScrollViewer { Content = cards, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollMode = ScrollMode.Disabled });
        }
        return new Border { Child = body, Padding = new(18), CornerRadius = new(20), Background = Design.Brush(Design.Dark ? Color.FromArgb(role == "user" ? (byte)60 : (byte)100, 120, 130, 150) : Color.FromArgb(role == "user" ? (byte)64 : (byte)128, 255, 255, 255)) };
    }

    void UpdateSend()
    {
        var asking = cancellation != null;
        send.Content = Design.Text(asking ? "■" : "↑", 20, true, Microsoft.UI.Colors.White);
        send.IsEnabled = asking || !string.IsNullOrWhiteSpace(question.Text);
        send.Background = Design.Brush(send.IsEnabled ? Design.Blue : Color.FromArgb(115, 130, 135, 145));
        AutomationProperties.SetName(send, asking ? "Stop answering" : "Send question");
    }

    void ScrollToEnd()
    {
        if (pendingBottomScroll != null) scroll.LayoutUpdated -= pendingBottomScroll;
        pendingBottomScroll = (_, _) =>
        {
            scroll.LayoutUpdated -= pendingBottomScroll;
            pendingBottomScroll = null;
            scroll.ChangeView(null, scroll.ScrollableHeight, null, true);
        };
        scroll.LayoutUpdated += pendingBottomScroll;
    }

    async Task Answer()
    {
        if (cancellation != null) { cancellation.Cancel(); return; }
        var text = question.Text.Trim(); if (text.Length == 0) return;
        lastQuestion = text; question.Text = ""; errorPanel.Visibility = Visibility.Collapsed;
        conversation.Turns.Add(new("user", text)); RenderConversation();
        var pending = Message("assistant", "Searching your memories…"); messages.Children.Add(pending);
        var body = ((StackPanel)pending.Child).Children.OfType<TextBlock>().First();
        cancellation = new(); var active = cancellation; var currentRevision = revision; UpdateSend();
        var ct = active.Token; string? pendingText = null;
        var timer = DispatcherQueue.CreateTimer(); timer.Interval = TimeSpan.FromMilliseconds(60);
        timer.Tick += (_, _) =>
        {
            if (currentRevision != revision || Interlocked.Exchange(ref pendingText, null) is not { } value) return;
            var followEnd = scroll.ScrollableHeight - scroll.VerticalOffset < 64;
            body.Text = value; if (followEnd) ScrollToEnd();
        };
        List<MemoryFrame> records = []; var completed = false;
        try
        {
            var (app, since) = scope();
            records = await Task.Run(() => runtime.Store.Retrieve(text, since: since, app: app, previous: conversation.History.LastOrDefault(x => x.Role == "user")?.Text), ct);
            ct.ThrowIfCancellationRequested();
            if (runtime.Settings.Chat.IsBuiltin) records = records.Take(5).ToList();
            if (records.Count == 0) { body.Text = "No relevant memories were found. Try an app name, a phrase you saw, or a date."; completed = true; return; }
            var transcripts = await Task.Run(() => records.Select(x => x.SessionId).Where(x => x != null).Distinct().SelectMany(x => runtime.Store.Transcript(x!)).ToList(), ct);
            ct.ThrowIfCancellationRequested(); body.Text = "Preparing answer…"; timer.Start();
            var result = await ModelClient.Answer(text, records, transcripts, conversation.History, runtime.Settings.Chat, SecretStore.Read("chat"), ct, value => Interlocked.Exchange(ref pendingText, value));
            ct.ThrowIfCancellationRequested(); body.Text = result;
            conversation.History.Add(new("user", text)); conversation.History.Add(new("assistant", result, records)); completed = true;
        }
        catch (OperationCanceledException) { body.Text = string.IsNullOrWhiteSpace(body.Text) || body.Text is "Preparing answer…" or "Searching your memories…" ? "Stopped." : body.Text; }
        catch (Exception ex)
        {
            if (currentRevision == revision)
            {
                body.Text = "The answer could not be completed.";
                errorText.Text = ex.Message;
                errorPanel.Visibility = Visibility.Visible;
            }
        }
        finally
        {
            timer.Stop();
            if (ReferenceEquals(cancellation, active)) { cancellation = null; UpdateSend(); }
            active.Dispose();
            if (currentRevision == revision)
            {
                var followEnd = scroll.ScrollableHeight - scroll.VerticalOffset < 64;
                conversation.Turns.Add(new("assistant", body.Text, completed ? records : null));
                var pendingIndex = messages.Children.IndexOf(pending);
                if (pendingIndex >= 0) messages.Children[pendingIndex] = Message("assistant", body.Text, completed ? records : null);
                if (followEnd) ScrollToEnd();
            }
        }
    }
}
