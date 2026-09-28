using System.Diagnostics;
using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.ApplicationModel.DataTransfer;

namespace Recall;

/// Retained card surfaces. Pointer events only retarget springs; the shared
/// projection is also used to pick the frontmost card, without XAML relayout.
internal sealed class RhineArchiveView : Grid
{
    // The wall is rendered and picked by RhineArchiveView as one interactive
    // archive. Its hundreds of decorative text/image peers add no usable UIA
    // actions, but make foreground focus and structure queries traverse every
    // card during an animation. Keep the real day/action controls outside it.
    sealed class DecorativeWall : Canvas
    {
        protected override AutomationPeer OnCreateAutomationPeer() => new DecorativeWallPeer(this);
    }
    sealed class DecorativeWallPeer(DecorativeWall owner) : FrameworkElementAutomationPeer(owner)
    {
        static readonly IList<AutomationPeer> noChildren = Array.Empty<AutomationPeer>();
        protected override IList<AutomationPeer> GetChildrenCore() => noChildren;
        protected override bool IsControlElementCore() => false;
        protected override bool IsContentElementCore() => false;
    }
    sealed class Sheet
    {
        public required Canvas Root;
        public required Border Glass;
        public Border? FocusGlass;
        public required Visual GlassVisual;
        public Visual? FocusVisual;
        public Visual? ArtVisual, FooterVisual, ImageVisual, FogVisual, DepthFogVisual, ActionVisual;
        public Grid? Art;
        public Image? Image;
        public Grid? Footer;
        public Grid? Heading;
        public TextBlock? TitleText, DateText;
        public Border? FooterFog;
        public Grid? Actions;
        public Border[]? ActionBorders;
        public TextBlock[]? ActionLabels;
        public FontIcon[]? ActionSymbols;
        public StackPanel[]? ActionContents;
        public TextBlock? StarLabel;
        public required Visual Visual;
        public ArchiveFrame? Frame;
        public int Lane, Row;
        public double Depth;
        public RhineSpring Height;
        public Matrix3x2 Matrix;
        public RhineGeometry.CardLayout Layout;
        public Vector3 Position;
        public float Width = 535, Size = 650, Distance, SortDistance, Aspect = 1.6f, ExpandedAspect = 1.6f, ShapedAspect;
        public float FooterRasterScale = 1, ShapedFooterRasterScale = 1, ExpandedProjectedScale = 1;
        public bool Loading, Failed, GlassAttached, ExpandedTypography;
        public int ImageEdge, LoadingEdge, LoadSerial;
        public BitmapImage? PendingImage;
        public int PendingEdge;
        public int ZIndex = -1;
        public float DrawOpacity = -1, ImageOpacity = -1, FogOpacity = -1, DepthFogOpacity = -1,
            GlassOpacity = -1, ActionOpacity = -1;
    }
    sealed class DayTag
    {
        public required Canvas Root;
        public required TextBlock Text;
        public required Visual Visual;
        public int Lane;
        public float Depth;
    }
    readonly AppRuntime runtime;
    readonly Action<MemoryFrame> rewind;
    readonly DecorativeWall wall = new() { IsHitTestVisible = false };
    readonly List<Sheet> sheets = [];
    readonly List<Sheet> drawOrder = [];
    readonly Dictionary<int, DayTag> dayTags = [];
    // WinUI Canvas rejects very large ZIndex values; realized sheets remain
    // viewport-bounded and are ranked far below this decorative front layer.
    const int FrontCopyZIndex = 10_000;
    readonly List<(Sheet Sheet, int Edge, float Priority)> pendingImages = [];
    readonly Dictionary<(int Lane, int Row), Sheet> realized = [];
    Dictionary<int, ArchiveFrame[]> columns = [];
    Dictionary<int, ImageBrush> palettes = [];
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer imageTimer;
    const int MaxImageRequests = 4;
    int imagePumpQueued;
    int pendingFlushQueued;
    bool awaitingFirstImage;
    readonly System.Threading.Timer motionClock;
    readonly Microsoft.UI.Dispatching.DispatcherQueue uiQueue;
    int frameQueued;
    long frameQueuedAt, lastClockTick;
    double transitionMaxQueueMs, transitionMaxClockIntervalMs;
    int transitionClockTicks;
    readonly Border caption;
    readonly Grid bottomDock = new() { VerticalAlignment = VerticalAlignment.Bottom, Margin = new(24, 0, 24, 16), ColumnSpacing = 12 };
    readonly Border dayPill;
    readonly TextBlock dayHint = Design.Text("One day per column", 11, color: Design.Muted);
    readonly TextBlock collectionText = Design.Text("", 10, color: Design.Muted);
    readonly TextBlock statusText = Design.Text("", 10, color: Design.Muted);
    readonly TextBlock captionText = Design.Text("", 14, true);
    readonly StackPanel dayControls;
    readonly Border extractedControls;
    readonly MatrixTransform extractedTransform = new();
    Matrix3x2 inputMatrix;
    readonly AccessibilityGrid extractedAutomation = new() { ExposeChildren = false, IsHitTestVisible = false };
    readonly TextBlock extractedTitle = Design.Text("", 14, true), extractedDate = Design.Text("", 11, color: Design.Muted);
    readonly Button starAction;
    readonly Button[] extractedActionButtons;
    readonly TextBlock dayText = Design.Text("", 13, true);
    RhineSpring dragX = new(0), dragY = new(0); double dragTargetX, dragTargetY, dragOriginX, dragOriginY; Point pressPoint; bool pointerDown, didDrag;
    RhineSpring crest = new(0), across = new(0), pan = new(0);
    RhineTransition extraction = new(0);
    double crestTarget, acrossTarget, panTarget, extractTarget;
    long previous, transitionStarted;
    double lastTransitionMs, transitionMaxUpdateMs, transitionMaxIntervalMs;
    int transitionFrames, transitionSlowFrames, matrixWrites, imageRequests;
    string transitionDirection = "none";
    bool orderDirty = true;
    bool expandedControlsShown;
    bool extractedButtonsEnabled;
    bool ticking, active, reduced, timeline;
    float expandedTopInset, expandedBottomInset;
    Sheet? hovered, extracted, frontCopy;
    DateTime day;
    DateTime? pendingDay;
    List<ArchiveFrame> records = [];
    sealed record PreparedArchive(List<ArchiveFrame> Frames, Dictionary<int,ArchiveFrame[]> Columns,
        Dictionary<string,(int Lane,int Row)> Positions, string Summary, int Rows, bool SameAsPrevious);
    int revision, rows = 20;
    long appliedArchiveRevision = -1;
    Task? runningRefresh;
    DateTime? runningRefreshAnchor;
    int runningRefreshRevision;
    int seekRevision;
    string? seekTargetId;
    int seekTargetRow = -1;
    CancellationTokenSource archiveQueries = new();
    CancellationTokenSource imageLoads = new();
    int pointerMoves, hoverChanges, expansions, collapses;
    int builds, reconciles, lastReusedSheets, lastReusedImages, refreshCacheHits, archiveQueryCount,
        imagesLoadedSinceBuild, evictedSheets, releasedImages;
    bool darkAtBuild;
    string collectionSummary = "";
    long buildEndedAt;
    double lastQueryMs, lastBuildMs, maxBuildMs, lastReconcileMs, firstImageMs, imageLoadTotalMs, maxImageLoadMs;
    internal object Diagnostics => new { motionProfile = new { transitionDirection, lastTransitionMs, transitionFrames, transitionSlowFrames, transitionMaxUpdateMs, transitionMaxIntervalMs, transitionMaxQueueMs, transitionMaxClockIntervalMs, transitionClockTicks, framePending = Volatile.Read(ref frameQueued) != 0, matrixWrites, imageRequests, imagePumpRunning = imageTimer.IsRunning }, startup = new { builds, incrementalUpdates = reconciles, reusedSheets = lastReusedSheets, reusedImages = lastReusedImages, cacheHits = refreshCacheHits, queryCount = archiveQueryCount, lastReconcileMs, lastQueryMs, lastBuildMs, maxBuildMs, sheetCount = sheets.Count, evictedSheets, releasedImages, retainedImageBytes = sheets.Sum(ImageBytes), deferredImages = sheets.Count(s => s.PendingImage != null), firstImageMs, imagesLoadedSinceBuild, imageLoadTotalMs, maxImageLoadMs }, archive = ArchiveDiagnostics(), card = CardDiagnostics(), footer = FooterDiagnostics(), safeArea = new { top = expandedTopInset, bottom = (float)ActualHeight - expandedBottomInset, bottomInset = expandedBottomInset, timelineVisible = timeline, dockHeight = bottomDock.ActualHeight }, copyCount = frontCopy == null ? 0 : 1, active, ticking, dragTargetX, dragTargetY, pointerDown, reducedMotion = reduced, expandedActionsVisible = expandedControlsShown, extraction = extraction.Value, extractTarget, pointerMoves, hoverChanges, expansions, collapses, hovered = hovered?.Frame?.Id, extracted = extracted?.Frame?.Id, crestTarget, acrossTarget, imageCount = sheets.Count(s => s.Frame != null), visiblePhotoCards = sheets.Count(s => s.Frame != null && s.Root.Visibility == Visibility.Visible && NearViewport(s,0)), loadedImages = sheets.Count(s => s.Image?.Source != null), visibleLoadedImages = sheets.Count(s => s.Image?.Source != null && s.Root.Visibility == Visibility.Visible && NearViewport(s,0)), highResolutionImages = sheets.Count(s => s.ImageEdge == ExpandedImageEdge), failedImages = sheets.Count(s => s.Failed) };
    object ArchiveDiagnostics() => new { initialized = columns.Count != 0,
        indexedRecords = records.Count, maxRows = rows, seekTargetId, seekTargetRow,
        storeRevision = runtime.Store.ArchiveRevision, appliedArchiveRevision,
        columns = Enumerable.Range(-2,5).Select(lane =>
        {
            columns.TryGetValue(lane, out var entries);
            return new { lane, day = columns.Count == 0 ? null : day.AddDays(lane).ToString("yyyy-MM-dd"),
                count = entries?.Length ?? 0, firstId = entries?.FirstOrDefault()?.Id,
                lastId = entries?.LastOrDefault()?.Id };
        }).ToArray() };
    object? CardDiagnostics()
    {
        if (extracted is not { } card) return null;
        var layout = card.Layout; var m = card.Matrix;
        var footer = RhineGeometry.FooterMatrix(layout,m);
        var artBottom = Vector2.Transform(new(layout.ArtLeft,layout.ArtTop+layout.ArtHeight),m);
        var footerTop = Vector2.Transform(Vector2.Zero,footer);
        var proxyTop = Vector2.Transform(Vector2.Zero,inputMatrix);
        var center = Vector2.Transform(Vector2.Zero,m);
        var neighbors = sheets.Count(other => other != card && other.Root.Visibility == Visibility.Visible &&
            other.SortDistance < card.SortDistance && Vector2.Distance(Vector2.Transform(Vector2.Zero,other.Matrix),center) <
            (card.Width+other.Width)*MathF.Max(MathF.Abs(m.M11),MathF.Abs(m.M22)));
        static object Point(Vector2 point) => new { x = point.X, y = point.Y };
        var corners = new[] { Vector2.Transform(new(-card.Width/2,-card.Size/2),m),
            Vector2.Transform(new(card.Width/2,-card.Size/2),m),
            Vector2.Transform(new(card.Width/2,card.Size/2),m),
            Vector2.Transform(new(-card.Width/2,card.Size/2),m) };
        return new { id = card.Frame?.Id, lane = card.Lane, row = card.Row, distance = card.Distance,
            rank = drawOrder.IndexOf(card), zIndex = card.ZIndex, occludingNeighbors = neighbors,
            homeSortDistance = card.SortDistance, frontOpacity = frontCopy?.Visual.Opacity ?? 0,
            frontMatrixMatches = frontCopy?.Matrix == card.Matrix,
            footerRasterScale = card.FooterRasterScale, xamlTitleSize = card.TitleText?.FontSize,
            projectedTitleSize = card.TitleText?.FontSize *
                RhineGeometry.FooterScreenScale(layout,m) / card.FooterRasterScale,
            copyCount = frontCopy == null ? 0 : 1,
            imageAspect = card.ExpandedAspect, projectedActionOpacity = card.ActionOpacity,
            cardCorners = corners.Select(Point).ToArray(),
            cardBounds = new { left = corners.Min(p => p.X), top = corners.Min(p => p.Y),
                right = corners.Max(p => p.X), bottom = corners.Max(p => p.Y) },
            imageBottom = Point(artBottom), footerTop = Point(footerTop), actionTop = Point(proxyTop),
            imageFooterGap = Vector2.Distance(artBottom,footerTop), actionPlaneError = Vector2.Distance(footerTop,proxyTop) };
    }
    object FooterDiagnostics()
    {
        Rect Bounds(FrameworkElement element) => element.XamlRoot == null ? new Rect()
            : element.TransformToVisual(this).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
        var date = Bounds(dayPill); var captionRect = Bounds(caption);
        var collection = Bounds(collectionText); var status = Bounds(statusText);
        static bool Crosses(Rect a, Rect b) => a.Right > b.Left && b.Right > a.Left && a.Bottom > b.Top && b.Bottom > a.Top;
        return new { dockBounds = Bounds(bottomDock), dateBounds = date, captionBounds = captionRect,
            collectionBounds = collection, statusBounds = status,
            dateVisible = bottomDock.Visibility == Visibility.Visible,
            captionVisible = caption.Visibility == Visibility.Visible,
            collectionVisible = collectionText.Visibility == Visibility.Visible,
            statusVisible = statusText.Visibility == Visibility.Visible,
            overlaps = bottomDock.Visibility == Visibility.Visible &&
                (caption.Visibility == Visibility.Visible && Crosses(captionRect, date) ||
                collectionText.Visibility == Visibility.Visible && Crosses(collection, date) ||
                statusText.Visibility == Visibility.Visible && Crosses(status, date)) };
    }
    internal bool IsOverDayControls(Point point)
    {
        if (!active || timeline || bottomDock.Visibility != Visibility.Visible || dayPill.XamlRoot == null)
            return false;
        var bounds = dayPill.TransformToVisual(this)
            .TransformBounds(new Rect(0, 0, dayPill.ActualWidth, dayPill.ActualHeight));
        return bounds.Contains(point);
    }
    internal void ValidationRetarget(int step)
    {
        if (!active || extracted != null) return;
        acrossTarget = step % 3 - 1; crestTarget = step % 7 * RhineGeometry.RowPitch;
        Wake();
    }
    public bool IsExpanded => extracted != null;
    public event Action? TimelineRequested;
    public event Action<bool>? ExpansionChanged;
    public event Action? DockSizeChanged;
    public RhineArchiveView(AppRuntime runtime, Action<MemoryFrame> rewind)
    {
        this.runtime = runtime; this.rewind = rewind;
        uiQueue = DispatcherQueue;
        // Coalesce to one pending UI update. DispatcherQueueTimer and Rendering
        // can be starved by XAML image work; the clock itself must stay independent.
        motionClock = new(_ => QueueFrame(),null,Timeout.Infinite,Timeout.Infinite);
        imageTimer = DispatcherQueue.CreateTimer(); imageTimer.Interval = TimeSpan.FromMilliseconds(60);
        imageTimer.Tick += (_, _) => PumpImages();
        Background = Design.Brush(Microsoft.UI.Colors.Transparent);
        IsTabStop = true;
        Children.Add(wall);
        foreach (var label in new[] { collectionText, statusText })
        {
            label.CharacterSpacing = 180; label.VerticalAlignment = VerticalAlignment.Center;
            label.TextWrapping = TextWrapping.NoWrap; label.TextTrimming = TextTrimming.CharacterEllipsis;
            label.MaxLines = 1; label.IsHitTestVisible = false;
        }
        collectionText.HorizontalAlignment = HorizontalAlignment.Left;
        statusText.HorizontalAlignment = HorizontalAlignment.Right;
        var actionRow = new Grid { ColumnSpacing = 7, Height = 40, VerticalAlignment = VerticalAlignment.Bottom, Margin = new(8,0,8,4) };
        Button Proxy(string name, int index)
        {
            var button = new Button { Content = Design.Text(name, 13), MinHeight = 40, Height = 40,
                Padding = new(0), Background = Design.Brush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new(0), UseSystemFocusVisuals = false };
            AutomationProperties.SetName(button, name);
            button.Click += (_, _) => Act(index);
            button.GotFocus += (_, _) => SetActionFocus(index, true);
            button.LostFocus += (_, _) => SetActionFocus(index, false);
            return button;
        }
        starAction = Proxy("Star", 0);
        extractedActionButtons = [starAction, Proxy("Copy text", 1), Proxy("Rewind", 2), Proxy("Collapse", 3)];
        var actions = extractedActionButtons;
        for (int i = 0; i < actions.Length; i++) { actionRow.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); Grid.SetColumn(actions[i], i); actions[i].HorizontalAlignment = HorizontalAlignment.Stretch; actionRow.Children.Add(actions[i]); }
        extractedTitle.MaxLines = 1; extractedTitle.TextTrimming = TextTrimming.CharacterEllipsis;
        var heading = new Grid { Height = 22, VerticalAlignment = VerticalAlignment.Top, Margin = new(8,0,8,0) }; heading.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        heading.Children.Add(extractedTitle); Grid.SetColumn(extractedDate, 1); heading.Children.Add(extractedDate);
        var inputPanel = new Grid(); inputPanel.Children.Add(heading); inputPanel.Children.Add(actionRow);
        extractedControls = new Border { Child = inputPanel, Width = RhineGeometry.ArtBaseWidth, Height = 60,
            Background = Design.Brush(Microsoft.UI.Colors.Transparent), RenderTransform = extractedTransform };
        extractedControls.HorizontalAlignment = HorizontalAlignment.Left; extractedControls.VerticalAlignment = VerticalAlignment.Top;
        // The visible footer belongs to the depth-sorted card. This transparent
        // matching plane only supplies real pointer/keyboard/UIA actions once
        // the card has settled in front of the archive.
        extractedControls.Opacity = .001;
        extractedControls.IsHitTestVisible = false;
        AutomationProperties.SetAccessibilityView(extractedControls, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(extractedTitle, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(extractedDate, AccessibilityView.Raw);
        foreach (var button in extractedActionButtons)
        {
            button.IsEnabled = button.IsTabStop = false;
            AutomationProperties.SetAccessibilityView(button, AccessibilityView.Raw);
        }
        extractedControls.PointerPressed += (_, e) => e.Handled = true;
        extractedAutomation.Children.Add(extractedControls);
        Children.Add(extractedAutomation);
        caption = Design.Card(captionText, 28, 18);
        caption.HorizontalAlignment = HorizontalAlignment.Center;
        caption.VerticalAlignment = VerticalAlignment.Bottom;
        caption.Margin = new(0, 0, 0, 24);
        caption.Visibility = Visibility.Collapsed;
        Children.Add(caption);
        Button DayArrow(string glyph, string name, int delta)
        {
            var button = new Button { Content = Design.Symbol(glyph, 16), Width = 30, Height = 30,
                MinWidth = 30, MinHeight = 30, Padding = new(0), CornerRadius = new(15),
                Background = Design.Brush(Microsoft.UI.Colors.Transparent), BorderThickness = new(0),
                UseSystemFocusVisuals = true };
            ToolTipService.SetToolTip(button,name);
            AutomationProperties.SetName(button,name);
            button.Click += (_, _) => ShiftDay(delta);
            button.PointerEntered += (_, _) => button.Background = Design.Brush(Design.Dark
                ? Color.FromArgb(42,225,236,250) : Color.FromArgb(90,255,255,255));
            button.PointerExited += (_, _) => button.Background = Design.Brush(Microsoft.UI.Colors.Transparent);
            return button;
        }
        dayControls = Design.Row(16, DayArrow("\uE76B", "Previous day", -1), dayText, dayHint,
            DayArrow("\uE76C", "Next day", 1));
        // A 30 px arrow plus 3 px inset and 1 px rim makes a 38 px pill.
        // Its one 19 px glass radius matches that actual edge; arrows are plain.
        dayPill = new Border { Child = dayControls, CornerRadius = new(19), Padding = new(4,3,4,3),
            BorderThickness = new(1), BorderBrush = Design.RimBrush };
        GlassMaterial.Attach(dayPill,19);
        dayPill.HorizontalAlignment = HorizontalAlignment.Center;
        bottomDock.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        bottomDock.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        bottomDock.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        bottomDock.Children.Add(collectionText);
        Grid.SetColumn(dayPill, 1); bottomDock.Children.Add(dayPill);
        Grid.SetColumn(statusText, 2); bottomDock.Children.Add(statusText);
        Children.Add(bottomDock);
        bottomDock.SizeChanged += (_, _) => { caption.Margin = new(0, 0, 0, bottomDock.ActualHeight + 30); DockSizeChanged?.Invoke(); };
        dayPill.PointerPressed += (_, e) => e.Handled = true;
        dayText.Tapped += (_, e) => { TimelineRequested?.Invoke(); e.Handled = true; };
        PointerMoved += (_, e) =>
        {
            var point = e.GetCurrentPoint(this).Position;
            if (pointerDown && extracted == null)
            {
                var dx = point.X - pressPoint.X; var dy = point.Y - pressPoint.Y;
                if (didDrag || dx * dx + dy * dy > 36)
                {
                    didDrag = true; hovered = null; UpdateCaption();
                    dragTargetX = dragOriginX + dx; dragTargetY = dragOriginY + dy;
                    Wake(); e.Handled = true; return;
                }
            }
            if (!pointerDown) Move(point);
        };
        PointerExited += (_, _) => { if (!pointerDown) { hovered = null; UpdateCaption(); } };
        PointerPressed += (_, e) =>
        {
            var point = e.GetCurrentPoint(this);
            if (!point.Properties.IsLeftButtonPressed) return;
            Focus(FocusState.Pointer); pointerDown = true; didDrag = false; pressPoint = point.Position;
            dragOriginX = dragTargetX; dragOriginY = dragTargetY; CapturePointer(e.Pointer); e.Handled = true;
        };
        PointerReleased += (_, e) =>
        {
            if (!pointerDown) return;
            var dragged = didDrag; pointerDown = false; ReleasePointerCaptures(); imageTimer.Start();
            if (!dragged)
            {
                var hit = Pick(e.GetCurrentPoint(this).Position, out var localHit);
                if (extracted != null) { if (hit != extracted) Collapse(); }
                else if (hit?.Frame != null) Expand(hit);
            }
            QueuePendingFlush();
            e.Handled = true;
        };
        PointerCaptureLost += (_, _) => { pointerDown = false; if (active) { imageTimer.Start(); QueuePendingFlush(); } };
        PointerWheelChanged += (_, e) =>
        {
            if (extracted != null) return;
            var d = -e.GetCurrentPoint(this).Properties.MouseWheelDelta / 120.0;
            panTarget = Math.Clamp(panTarget + d * .9 * RhineGeometry.RowPitch, 0, RhineGeometry.LastScroll(rows));
            crestTarget = panTarget + d * .8 * RhineGeometry.RowPitch; acrossTarget = 0;
            hovered = null; UpdateCaption(); Wake(); e.Handled = true;
        };
        KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter && hovered?.Frame != null) { Expand(hovered); e.Handled = true; }
            else if (e.Key is Windows.System.VirtualKey.Up or Windows.System.VirtualKey.Down && extracted == null)
            {
                if (!columns.TryGetValue(0, out var column) || column.Length == 0) return;
                var index = hovered?.Lane == 0 ? hovered.Row : -1;
                var row = Math.Clamp(index + (e.Key == Windows.System.VirtualKey.Down ? 1 : -1), 0, column.Length - 1);
                hovered = EnsureSheet(0, row);
                crestTarget = hovered.Depth; acrossTarget = hovered.Lane; panTarget = Math.Clamp(hovered.Depth, 0, RhineGeometry.LastScroll(rows));
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, hovered.Frame!.Title + ", " + hovered.Frame.Timestamp.LocalDateTime.ToString("MMM d · HH:mm") + ". Enter to open.");
                UpdateCaption(); Wake(); e.Handled = true;
            }
            else if (extracted != null && e.Key is Windows.System.VirtualKey.S or Windows.System.VirtualKey.C or Windows.System.VirtualKey.R)
            { Act(e.Key == Windows.System.VirtualKey.S ? 0 : e.Key == Windows.System.VirtualKey.C ? 1 : 2); e.Handled = true; }
            else if (e.Key is Windows.System.VirtualKey.Left or Windows.System.VirtualKey.Right) { ShiftDay(e.Key == Windows.System.VirtualKey.Left ? -1 : 1); e.Handled = true; }
        };
        SizeChanged += (_, _) => { Clip = new RectangleGeometry { Rect = new(0, 0, ActualWidth, ActualHeight) }; UpdateStatus(); UpdateExpandedRaster(); Wake(); };
        Unloaded += (_, _) => SetActive(false);
        AutomationProperties.SetName(this, "Rhine archive");
        AutomationProperties.SetHelpText(this, "Use Up or Down to select a memory, Enter to open it, and Left or Right to change day.");
    }
    public Task Refresh(DateTime? anchor = null)
    {
        anchor = anchor?.Date;
        if (runningRefresh is { IsCompleted: false } task && runningRefreshAnchor == anchor &&
            runningRefreshRevision == revision && !archiveQueries.IsCancellationRequested)
            return task;
        runningRefreshAnchor = anchor;
        var started = RefreshCore(anchor);
        runningRefreshRevision = revision;
        return runningRefresh = started;
    }
    async Task RefreshCore(DateTime? anchor)
    {
        // The store revision is captured before the query. A write during that
        // query must remain visible as a later revision, not be marked applied.
        var storeRevision = runtime.Store.ArchiveRevision;
        if (columns.Count != 0 && (anchor == null || anchor == day) &&
            darkAtBuild == Design.Dark && storeRevision == appliedArchiveRevision)
        {
            refreshCacheHits++;
            reduced = !Design.Motion;
            UpdateStatus();
            return;
        }
        var version = ++revision;
        archiveQueries.Cancel(); archiveQueries.Dispose(); archiveQueries = new();
        var queryToken = archiveQueries.Token;
        var started = Stopwatch.GetTimestamp();
        // Query only the five local days shown by this rack. The archive query
        // leaves OCR text/regions on disk until an action actually needs them.
        var nextDay = anchor?.Date ?? (columns.Count != 0 ? day
            : await Task.Run(() => runtime.Store.LatestArchiveDay()) ?? DateTime.Today);
        if (version != revision) return;
        var previous = records.ToArray();
        PreparedArchive prepared;
        archiveQueryCount++;
        try { prepared = await Task.Run(() => PrepareArchive(
            runtime.Store.ArchiveIndex(nextDay, cancellation: queryToken), nextDay, previous, queryToken), queryToken); }
        catch (OperationCanceledException) { return; }
        if (version != revision) return;
        lastQueryMs = (Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency;
        // A return from settings/search is a refresh of the existing archive,
        // not a request to jump back to the newest day the user already left.
        if (columns.Count != 0 && nextDay == day && darkAtBuild == Design.Dark && prepared.SameAsPrevious)
        {
            // Returning home with the same records should preserve the rack,
            // decoded images, scroll and focused card instead of rebuilding it.
            appliedArchiveRevision = storeRevision;
            reduced = !Design.Motion; UpdateStatus();
            if (active && runtime.Store.ArchiveRevision != storeRevision)
                DispatcherQueue.TryEnqueue(() => _ = Refresh());
            return;
        }
        if (columns.Count != 0 && nextDay == day && darkAtBuild == Design.Dark)
            Reconcile(prepared);
        else
        {
            records = prepared.Frames;
            day = nextDay;
            Build(prepared);
        }
        appliedArchiveRevision = storeRevision;
        if (active && runtime.Store.ArchiveRevision != storeRevision)
            DispatcherQueue.TryEnqueue(() => _ = Refresh());
    }
    static PreparedArchive PrepareArchive(List<ArchiveFrame> frames, DateTime day,
        IReadOnlyList<ArchiveFrame> previous, CancellationToken token)
    {
        var buckets = Enumerable.Range(-2,5).ToDictionary(lane => lane, _ => new List<ArchiveFrame>());
        var apps = new HashSet<string>(StringComparer.Ordinal);
        foreach (var frame in frames)
        {
            token.ThrowIfCancellationRequested();
            var lane = (frame.Timestamp.LocalDateTime.Date - day).Days;
            if (buckets.TryGetValue(lane,out var bucket)) bucket.Add(frame);
            apps.Add(frame.AppName);
        }
        var columns = buckets.ToDictionary(entry => entry.Key, entry => entry.Value.ToArray());
        var positions = new Dictionary<string,(int Lane,int Row)>(frames.Count,StringComparer.Ordinal);
        foreach (var (lane, entries) in columns)
            for (var row = 0; row < entries.Length; row++) positions[entries[row].Id] = (lane,row);
        return new(frames,columns,positions,$"LOCAL COLLECTION · {apps.Count:N0} APPS / {frames.Count:N0} MEMORIES",
            Math.Max(52,columns.Values.Max(items => items.Length)),SameFrames(previous,frames));
    }
    static bool SameFrames(IReadOnlyList<ArchiveFrame> before, IReadOnlyList<ArchiveFrame> after)
    {
        if (before.Count != after.Count) return false;
        for (var i = 0; i < before.Count; i++)
            if (before[i] != after[i]) return false;
        return true;
    }
    void Reconcile(PreparedArchive prepared)
    {
        var started = Stopwatch.GetTimestamp();
        var anchor = extracted ?? hovered ?? sheets.Where(s => s.Frame != null)
            .MinBy(s => Math.Abs(s.Depth-pan.Value));
        var anchorId = anchor?.Frame?.Id;
        var oldAnchorDepth = anchor?.Depth ?? 0;
        var kept = 0; var keptImages = 0;
        if (extracted?.Frame is { } selected && !prepared.Positions.ContainsKey(selected.Id))
        {
            ReleaseFrontCopy();
            SetFooterRaster(extracted,1,1,false);
            RemoveProjectedActions(extracted);
            extracted.FocusVisual!.Opacity = 0;
            extracted = null; extraction = new(0); extractTarget = 0;
            SetExpandedControlsVisible(false); ExpansionChanged?.Invoke(false);
        }
        realized.Clear();
        foreach (var sheet in sheets.ToArray())
        {
            ArchiveFrame? updated = null;
            var keepEmpty = sheet.Frame == null &&
                (sheet.Row < 0 || sheet.Row >= prepared.Columns[sheet.Lane].Length);
            if (sheet.Frame is { } old && prepared.Positions.TryGetValue(old.Id,out var position))
            {
                updated = prepared.Columns[position.Lane][position.Row];
                var changedPath = !StringComparer.Ordinal.Equals(old.ImagePath,updated.ImagePath);
                if (sheet.Lane != position.Lane) sheet.Glass.Background = palettes[position.Lane];
                sheet.Lane = position.Lane; sheet.Row = position.Row;
                sheet.Depth = RhineGeometry.Depth(position.Row,position.Lane);
                sheet.Frame = updated;
                if (old != updated)
                {
                    if (sheet.TitleText != null) sheet.TitleText.Text =
                        string.IsNullOrWhiteSpace(updated.Title) ? updated.AppName : updated.Title;
                    if (sheet.DateText != null) sheet.DateText.Text =
                        updated.Timestamp.LocalDateTime.ToString("MMM d, yyyy  HH:mm");
                    if (sheet.StarLabel != null) sheet.StarLabel.Text = updated.Starred ? "Starred" : "Star";
                    if (sheet == extracted)
                    {
                        extractedTitle.Text = updated.Title;
                        extractedDate.Text = updated.Timestamp.LocalDateTime.ToString("MMM d · HH:mm");
                        var starName = updated.Starred ? "Starred" : "Star";
                        starAction.Content = Design.Text(starName,13);
                        AutomationProperties.SetName(starAction,starName);
                        if (frontCopy != null)
                        {
                            frontCopy.Frame = updated;
                            if (frontCopy.TitleText != null) frontCopy.TitleText.Text = sheet.TitleText?.Text ?? "";
                            if (frontCopy.DateText != null) frontCopy.DateText.Text = sheet.DateText?.Text ?? "";
                            if (frontCopy.StarLabel != null) frontCopy.StarLabel.Text = starName;
                        }
                    }
                }
                if (changedPath)
                {
                    if (sheet.Image != null) sheet.Image.Source = null;
                    sheet.LoadSerial++; sheet.Loading = false; sheet.LoadingEdge = 0;
                    sheet.ImageEdge = sheet.PendingEdge = 0; sheet.PendingImage = null; sheet.Failed = false;
                    if (sheet == extracted && frontCopy?.Image != null) frontCopy.Image.Source = null;
                }
                else if (sheet.Image?.Source != null) keptImages++;
            }
            if (updated == null && !keepEmpty)
            {
                if (sheet == hovered) hovered = null;
                if (sheet.Image != null) sheet.Image.Source = null;
                sheet.PendingImage = null; sheet.PendingEdge = 0;
                wall.Children.Remove(sheet.Root); sheets.Remove(sheet); drawOrder.Remove(sheet);
                continue;
            }
            realized[(sheet.Lane,sheet.Row)] = sheet;
            kept++;
        }
        records = prepared.Frames; columns = prepared.Columns; rows = prepared.Rows;
        collectionSummary = prepared.Summary;
        RefreshDayTags();
        if (anchorId != null && prepared.Positions.TryGetValue(anchorId,out var newAnchor))
        {
            var shift = RhineGeometry.Depth(newAnchor.Row,newAnchor.Lane)-oldAnchorDepth;
            var lastScroll = RhineGeometry.LastScroll(rows);
            pan.Value = Math.Clamp(pan.Value+shift,0,lastScroll);
            panTarget = Math.Clamp(panTarget+shift,0,lastScroll);
            crest.Value += shift; crestTarget += shift;
        }
        lastReusedSheets = kept; lastReusedImages = keptImages; reconciles++;
        lastReconcileMs = (Stopwatch.GetTimestamp()-started)*1000.0/Stopwatch.Frequency;
        reduced = !Design.Motion; orderDirty = true; UpdateCaption(); Wake();
        if (active) imageTimer.Start();
    }
    public void SetTimeline(bool visible)
    {
        if (timeline == visible) return;
        timeline = visible;
        bottomDock.Visibility = visible ? Visibility.Collapsed : Visibility.Visible;
        UpdateCaption();
    }
    public bool TimelineVisible => timeline;
    public double DateDockReserve => Math.Max(40, bottomDock.ActualHeight) + bottomDock.Margin.Bottom;
    public void SetExpandedSafeArea(double top, double bottom)
    {
        var nextTop = (float)Math.Max(0, top);
        var nextBottom = (float)Math.Max(0, bottom);
        if (Math.Abs(expandedTopInset - nextTop) < .1f && Math.Abs(expandedBottomInset - nextBottom) < .1f) return;
        expandedTopInset = nextTop; expandedBottomInset = nextBottom;
        UpdateExpandedRaster();
        Wake();
    }
    void UpdateExpandedRaster()
    {
        if (extracted is not { } sheet || ActualWidth < 100 || ActualHeight < 100) return;
        var (openWidth, openHeight) = RhineGeometry.ExpandedSize(sheet.ExpandedAspect,
            (float)ActualWidth, (float)ActualHeight, expandedTopInset, expandedBottomInset);
        var view = RhineGeometry.View((float)pan.Value);
        Matrix4x4.Invert(view, out var camera);
        var destination = Vector3.Transform(new Vector3(0,0,-14), camera);
        var finalMatrix = RhineGeometry.Plane(destination, Quaternion.CreateFromRotationMatrix(camera), view,
            (float)ActualWidth, (float)ActualHeight);
        var finalScale = RhineGeometry.FooterScreenScale(
            RhineGeometry.Layout(openWidth, openHeight, sheet.ExpandedAspect), finalMatrix);
        if (finalScale < .05f || !float.IsFinite(finalScale)) return;
        if (Math.Abs(sheet.FooterRasterScale - Math.Max(1, finalScale)) < .01f &&
            Math.Abs(sheet.ExpandedProjectedScale - finalScale) < .01f) return;
        SetFooterRaster(sheet, Math.Max(1, finalScale), finalScale, true);
        sheet.Footer?.UpdateLayout();
        if (frontCopy is { } copy)
        {
            SetFooterRaster(copy, sheet.FooterRasterScale, sheet.ExpandedProjectedScale, true);
            copy.Footer?.UpdateLayout();
            SyncFrontCopy(sheet, (float)extraction.Value);
        }
    }
    public void UpdateStatus()
    {
        var visible = !timeline && extracted == null && ActualWidth >= 1100;
        collectionText.Visibility = statusText.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        dayHint.Visibility = ActualWidth >= 720 ? Visibility.Visible : Visibility.Collapsed;
        dayControls.Spacing = ActualWidth >= 520 ? 12 : 5;
        if (collectionText.Text != collectionSummary) collectionText.Text = collectionSummary;
        var recording = runtime.Recording.State;
        var appearance = Design.Dark ? "DARK MODE" : "LIGHT MODE";
        var status = recording.CaptureFaulted && recording.Requested ? $"{appearance} · RECORDING INTERRUPTED"
            : recording.Requested ? $"{appearance} · RECORDING PAUSED" : $"{appearance} · RECORDING OFF";
        if (statusText.Text != status) statusText.Text = status;
    }
    public void SetActive(bool value)
    {
        if (active == value && Visibility == (value ? Visibility.Visible : Visibility.Collapsed)) return;
        active = value;
        Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        if (value)
        {
            if (imageLoads.IsCancellationRequested)
            { imageLoads.Dispose(); imageLoads = new(); }
            if (archiveQueries.IsCancellationRequested)
            { archiveQueries.Dispose(); archiveQueries = new(); }
            if (extracted != null && frontCopy == null) CreateFrontCopy(extracted);
            if (sheets.Any(s => s.Frame != null && s.Image?.Source == null)) imageTimer.Start();
            Wake();
        }
        else
        {
            ReleaseFrontCopy();
            pointerDown = false; pendingDay = null; ReleasePointerCaptures(); Stop(); imageTimer.Stop(); ++revision; ++seekRevision; imageLoads.Cancel(); archiveQueries.Cancel(); pendingImages.Clear();
            runningRefresh = null; runningRefreshAnchor = null; runningRefreshRevision = 0;
            foreach (var sheet in sheets)
            { sheet.LoadSerial++; sheet.Loading = false; sheet.LoadingEdge = 0;
                sheet.PendingImage = null; sheet.PendingEdge = 0; }
        }
    }
    public void Seek(MemoryFrame frame, bool expand = false)
    {
        var request = ++seekRevision;
        if (frame.Timestamp.LocalDateTime.Date != day)
        {
            _ = SeekInDay(frame, expand, request);
            return;
        }
        SeekLoaded(frame, expand);
    }
    async Task SeekInDay(MemoryFrame frame, bool expand, int request)
    {
        var target = frame.Timestamp.LocalDateTime.Date;
        await Refresh(target);
        if (active && request == seekRevision && day == target) SeekLoaded(frame, expand);
    }
    void SeekLoaded(MemoryFrame frame, bool expand)
    {
        if (!records.Any(f => f.Id == frame.Id))
            records.Add(new ArchiveFrame(frame.Id, frame.Timestamp, frame.AppName, frame.Title, frame.ImagePath, frame.Starred));
        if (!columns.Values.Any(items => items.Any(item => item.Id == frame.Id))) Build();
        var sheet = sheets.FirstOrDefault(s => s.Frame?.Id == frame.Id);
        if (sheet == null)
            foreach (var (lane, entries) in columns)
            {
                var row = Array.FindIndex(entries, item => item.Id == frame.Id);
                if (row >= 0) { sheet = EnsureSheet(lane, row); break; }
            }
        if (sheet == null || extracted == sheet && extractTarget == 1) return;
        seekTargetId = frame.Id; seekTargetRow = sheet.Row;
        if (extracted is { } old)
        {
            ReleaseFrontCopy();
            SetFooterRaster(old, 1, 1, false);
            old.FocusVisual!.Opacity = 0; RemoveProjectedActions(old); old.ExpandedAspect = old.Aspect;
            Shape(old,535,650); orderDirty = true;
            extracted = null; extraction = new(0); extractTarget = 0; SetExpandedControlsVisible(false); ExpansionChanged?.Invoke(false);
        }
        dragTargetX = dragTargetY = 0; panTarget = Math.Clamp(sheet.Depth, 0, RhineGeometry.LastScroll(rows));
        crestTarget = sheet.Depth; acrossTarget = sheet.Lane;
        // Deep seeks jump directly into the destination window. Springing past
        // thousands of rows materialized every intermediate viewport.
        if (Math.Abs(panTarget-pan.Value) > 12*RhineGeometry.RowPitch)
        {
            pan = new(panTarget); crest = new(crestTarget); across = new(acrossTarget);
            dragX = dragY = new(0);
            foreach (var candidate in sheets)
                candidate.Height = new(RhineGeometry.Height(candidate.Lane,candidate.Depth,crestTarget,acrossTarget));
            orderDirty = true;
        }
        if (expand) Expand(sheet);
        Wake();
    }
    async void ShiftDay(int delta)
    {
        ++seekRevision;
        if (extracted != null) Collapse();
        var target = (pendingDay ?? day).AddDays(delta);
        pendingDay = target;
        await Refresh(target);
        if (day == target) pendingDay = null;
    }
    void Build(PreparedArchive? prepared = null)
    {
        var started = Stopwatch.GetTimestamp();
        imageLoads.Cancel(); imageLoads.Dispose(); imageLoads = new();
        Stop(); imageTimer.Stop(); awaitingFirstImage = false; orderDirty = true; ReleaseFrontCopy(); wall.Children.Clear(); sheets.Clear(); drawOrder.Clear(); dayTags.Clear(); realized.Clear(); pendingImages.Clear(); extracted = hovered = null;
        seekTargetId = null; seekTargetRow = -1;
        ExpansionChanged?.Invoke(false);
        dragX = dragY = new(0); dragTargetX = dragTargetY = 0;
        crest = new(0); across = new(0); pan = new(0); crestTarget = acrossTarget = panTarget = 0;
        extraction = new(0); extractTarget = 0; SetExpandedControlsVisible(false);
        dayText.Text = day.ToString("MMM d, yyyy");
        AutomationProperties.SetName(this, $"Rhine archive, {day:MMMM d, yyyy}");
        prepared ??= PrepareArchive(records,day,[],CancellationToken.None);
        columns = prepared.Columns; collectionSummary = prepared.Summary; rows = prepared.Rows;
        // Recent rows extend behind the crest instead of leaving the upper rack empty.
        var initialDepth = Math.Min(8, Math.Max(0, columns[0].Length - 1)) * RhineGeometry.RowPitch;
        pan = new(panTarget = initialDepth); crest = new(crestTarget = initialDepth);
        palettes = Enumerable.Range(-2,5).ToDictionary(l => l, CreateGlass);
        RefreshDayTags();
        darkAtBuild = Design.Dark;
        reduced = !Design.Motion; UpdateCaption(); Wake(); imageTimer.Start();
        builds++; lastBuildMs = (Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency;
        maxBuildMs = Math.Max(maxBuildMs, lastBuildMs);
        buildEndedAt = Stopwatch.GetTimestamp(); firstImageMs = imageLoadTotalMs = maxImageLoadMs = 0; imagesLoadedSinceBuild = 0;
    }
    Sheet EnsureSheet(int lane, int row)
    {
        if (realized.TryGetValue((lane, row), out var existing)) return existing;
        var frames = columns[lane];
        var frame = row >= 0 && row < frames.Length ? frames[row] : null;
        var sheet = CreateSheet(lane,row,frame);
        realized[(lane, row)] = sheet;
        sheets.Add(sheet); drawOrder.Add(sheet); wall.Children.Add(sheet.Root);
        orderDirty = true;
        if (active && !imageTimer.IsRunning) imageTimer.Start();
        return sheet;
    }
    void RefreshDayTags()
    {
        if (columns.Count == 0) return;
        foreach (var lane in Enumerable.Range(-2,5))
        {
            var count = columns.TryGetValue(lane,out var entries) ? entries.Length : 0;
            var label = $"{day.AddDays(lane):MM/dd}   ·   {(count == 0 ? "No memories" : $"{count} memories")}";
            if (!dayTags.TryGetValue(lane,out var tag))
            {
                var text = Design.Text(label,12,true,Design.Dark ? Color.FromArgb(225,242,244,248) : Color.FromArgb(205,55,57,61));
                text.FontFamily = new FontFamily("Cascadia Mono");
                text.FontWeight = Microsoft.UI.Text.FontWeights.Medium;
                text.TextWrapping = TextWrapping.NoWrap;
                text.Width = 430; text.Height = 43;
                var root = new Canvas { Width = 0, Height = 0, IsHitTestVisible = false };
                Canvas.SetLeft(text,-215); Canvas.SetTop(text,-21.5); root.Children.Add(text);
                Canvas.SetZIndex(root,FrontCopyZIndex-1);
                tag = new DayTag { Root = root, Text = text, Visual = ElementCompositionPreview.GetElementVisual(root), Lane = lane,
                    Depth = RhineGeometry.Depth(0,lane) };
                dayTags[lane] = tag; wall.Children.Add(root);
            }
            tag.Text.Text = label;
            tag.Text.Foreground = Design.Brush(Design.Dark ? Color.FromArgb(225,242,244,248) : Color.FromArgb(205,55,57,61));
            tag.Depth = RhineGeometry.Depth(0,lane);
        }
    }
    Sheet CreateSheet(int lane, int row, ArchiveFrame? frame)
    {
        var depth = RhineGeometry.Depth(row,lane);
        var root = new Canvas { Width = 0, Height = 0 };
        var rimScale = frame == null ? .80 : 1;
        var glass = new Border { Width = 535, Height = 650, Background = palettes[lane], BorderBrush = new LinearGradientBrush { StartPoint = new(0,0), EndPoint = new(.7,1), GradientStops = { new() { Offset = 0, Color = Color.FromArgb((byte)(210*rimScale),255,255,255) }, new() { Offset = .45, Color = Color.FromArgb((byte)(142*rimScale),246,249,250) }, new() { Offset = 1, Color = Color.FromArgb((byte)(54*rimScale),179,193,203) } } }, BorderThickness = new(frame == null ? 1.7 : 2.7,frame == null ? 1.4 : 2.2,0,0), CornerRadius = new(2) };
        var depthFog = new Border { Width = 535, Height = 650, CornerRadius = new(2),
            Background = Design.Brush(Design.Dark ? Color.FromArgb(255,15,18,24) : Color.FromArgb(255,230,228,221)),
            IsHitTestVisible = false };
        Border? focusGlass = null, fog = null;
        Image? image = null;
        Grid? art = null, footer = null, heading = null;
        TextBlock? titleText = null, dateText = null;
        root.Children.Add(glass);
        if (frame != null)
        {
            focusGlass = new Border { Width = 535, Height = 650, CornerRadius = new(2), IsHitTestVisible = false };
            image = new Image { Width = RhineGeometry.ArtBaseWidth, Height = RhineGeometry.ArtBaseWidth / 1.6, Stretch = Stretch.Uniform };
            art = new Grid { Width = RhineGeometry.ArtBaseWidth, Height = RhineGeometry.ArtBaseWidth / 1.6, Background = Design.Brush(Design.Dark ? Color.FromArgb(110, 80, 83, 90) : Color.FromArgb(65, 255, 255, 255)) };
            art.Children.Add(image);
            footer = new Grid { Width = RhineGeometry.ArtBaseWidth, Height = RhineGeometry.FooterBaseHeight,
                Background = Design.Brush(Design.Dark ? Color.FromArgb(248, 30, 34, 40) : Color.FromArgb(248, 255, 255, 255)),
                IsHitTestVisible = false };
            var info = new Grid { Height = 22, VerticalAlignment = VerticalAlignment.Top, Margin = new(9,0,9,0) };
            heading = info;
            info.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            info.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var title = Design.Text(string.IsNullOrWhiteSpace(frame.Title) ? frame.AppName : frame.Title, 15, true);
            titleText = title;
            title.MaxLines = 1; title.TextTrimming = TextTrimming.CharacterEllipsis; title.TextWrapping = TextWrapping.NoWrap;
            info.Children.Add(title);
            var date = Design.Text(frame.Timestamp.LocalDateTime.ToString("MMM d, yyyy  HH:mm"), 12, color: Design.Muted);
            dateText = date;
            date.Margin = new(12,0,0,0); date.TextWrapping = TextWrapping.NoWrap;
            Grid.SetColumn(date,1); info.Children.Add(date); footer.Children.Add(info);
            fog = new Border { Background = Design.Brush(Design.Dark ? Color.FromArgb(255,15,18,24) : Color.FromArgb(255,230,228,221)), IsHitTestVisible = false };
            footer.Children.Add(fog);
            root.Children.Add(focusGlass); root.Children.Add(art); root.Children.Add(footer);
        }
        root.Children.Add(depthFog);
        var h = RhineGeometry.Height(lane, depth, crestTarget, acrossTarget);
        var sheet = new Sheet { Root = root, Glass = glass, FocusGlass = focusGlass, GlassVisual = ElementCompositionPreview.GetElementVisual(glass), FocusVisual = focusGlass == null ? null : ElementCompositionPreview.GetElementVisual(focusGlass), ArtVisual = art == null ? null : ElementCompositionPreview.GetElementVisual(art), FooterVisual = footer == null ? null : ElementCompositionPreview.GetElementVisual(footer), ImageVisual = image == null ? null : ElementCompositionPreview.GetElementVisual(image), FogVisual = fog == null ? null : ElementCompositionPreview.GetElementVisual(fog), DepthFogVisual = ElementCompositionPreview.GetElementVisual(depthFog), Art = art, Image = image, Footer = footer, Heading = heading, TitleText = titleText, DateText = dateText, FooterFog = fog, Visual = ElementCompositionPreview.GetElementVisual(root), Frame = frame, Lane = lane, Row = row, Depth = depth, Height = new(h), Position = new(lane * (lane < 0 ? 5.65f : 6.25f), (float)h, (float)depth - 5) };
        sheet.DepthFogVisual.Opacity = 0;
        if (sheet.FocusVisual != null) sheet.FocusVisual.Opacity = 0;
        Shape(sheet, 535, 650);
        return sheet;
    }
    void CreateFrontCopy(Sheet source)
    {
        if (frontCopy != null || source.Frame == null) return;
        // One decorative sibling, never a second image decode or UIA/input target.
        // The original stays fully opaque in its home depth order. Fading only
        // this front copy keeps unoccluded pixels from dimming at a crossing.
        var copy = CreateSheet(source.Lane, source.Row, source.Frame);
        copy.Aspect = source.Aspect; copy.ExpandedAspect = source.ExpandedAspect;
        copy.Image!.Height = copy.Art!.Height = source.Image!.Height;
        copy.Image.Source = source.Image.Source;
        copy.Art.Background = source.Art!.Background;
        CreateProjectedActions(copy);
        SetFooterRaster(copy, source.FooterRasterScale, source.ExpandedProjectedScale, source.ExpandedTypography);
        Shape(copy, source.Width, source.Size);
        copy.GlassVisual.Opacity = .75f;
        copy.Visual.Opacity = 0;
        copy.Root.Visibility = source.Root.Visibility;
        Canvas.SetZIndex(copy.Root, FrontCopyZIndex);
        wall.Children.Add(copy.Root);
        copy.Root.UpdateLayout();
        frontCopy = copy;
    }
    void ReleaseFrontCopy()
    {
        if (frontCopy is not { } copy) return;
        wall.Children.Remove(copy.Root);
        copy.Image!.Source = null;
        copy.Frame = null;
        frontCopy = null;
    }
    void SyncFrontCopy(Sheet source, float progress)
    {
        if (frontCopy is not { } copy) return;
        copy.ExpandedAspect = source.ExpandedAspect;
        Shape(copy, source.Width, source.Size);
        if (copy.Matrix != source.Matrix)
        {
            copy.Matrix = source.Matrix;
            copy.Visual.TransformMatrix = RhineGeometry.Matrix(source.Matrix);
        }
        copy.Root.Visibility = source.Root.Visibility;
        if (copy.ImageOpacity != source.ImageOpacity)
        { copy.ImageVisual!.Opacity = source.ImageOpacity; copy.ImageOpacity = source.ImageOpacity; }
        if (copy.FogOpacity != source.FogOpacity)
        { copy.FogVisual!.Opacity = source.FogOpacity; copy.FogOpacity = source.FogOpacity; }
        if (copy.ActionOpacity != source.ActionOpacity)
        { copy.ActionVisual!.Opacity = source.ActionOpacity; copy.ActionOpacity = source.ActionOpacity; }
        var opacity = source.DrawOpacity * RhineGeometry.FrontBlend(progress);
        if (Math.Abs(copy.DrawOpacity-opacity) > .002f)
        { copy.Visual.Opacity = opacity; copy.DrawOpacity = opacity; }
    }
    static void SetFooterRaster(Sheet sheet, float raster, float projectedScale, bool expanded)
    {
        if (sheet.Footer == null) return;
        sheet.FooterRasterScale = raster;
        sheet.ExpandedProjectedScale = projectedScale;
        sheet.ExpandedTypography = expanded;
        // The footer is laid out at a higher XAML resolution, then reduced by
        // the inverse factor in Shape. Its projected bounds stay unchanged.
        sheet.Footer.Width = RhineGeometry.ArtBaseWidth * raster;
        sheet.Footer.Height = RhineGeometry.FooterBaseHeight * raster;
        var footerOnScreen = RhineGeometry.FooterBaseHeight * projectedScale;
        var compact = expanded && footerOnScreen < 52;
        var actionHeight = compact ? Math.Min(24, Math.Max(16, footerOnScreen * .55f)) : 26f * projectedScale;
        var headingHeight = compact ? Math.Max(0, footerOnScreen - actionHeight) : 22f * projectedScale;
        var screenToRaster = raster / Math.Max(.05f, projectedScale);
        sheet.Heading!.Height = compact ? headingHeight * screenToRaster : 22 * raster;
        sheet.Heading.Visibility = compact && headingHeight < 12 ? Visibility.Collapsed : Visibility.Visible;
        sheet.Heading.Margin = new((compact ? 6 : 9)*raster,0,(compact ? 6 : 9)*raster,0);
        sheet.DateText!.Margin = new(12*raster,0,0,0);
        sheet.DateText.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        var textScale = expanded ? raster / Math.Max(.01f, projectedScale) : 1;
        sheet.TitleText!.FontSize = expanded ? (compact ? 13 : 18)*textScale : 15;
        sheet.DateText.FontSize = expanded ? 14*textScale : 12;
        sheet.DateText.FontFamily = expanded ? Design.BodyFont : Design.SmallFont;
        if (sheet.Actions != null)
        {
            sheet.Actions.Height = compact ? actionHeight * screenToRaster : 26*raster;
            sheet.Actions.Margin = compact ? new(3*raster,0,3*raster,0) : new(8*raster,0,8*raster,4*raster);
            sheet.Actions.ColumnSpacing = (compact ? 3 : 7)*raster;
            for (var i = 0; i < sheet.ActionLabels!.Length; i++)
            {
                sheet.ActionLabels[i].FontSize = expanded ? 16*textScale : 13;
                sheet.ActionLabels[i].Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
                sheet.ActionSymbols![i].FontSize = expanded ? (compact ? 15 : 16.5)*textScale : 15;
                sheet.ActionContents![i].Spacing = (compact ? 0 : 6)*raster;
                sheet.ActionBorders![i].CornerRadius = new(10*raster);
                sheet.ActionBorders[i].BorderThickness = new(raster);
            }
        }
        Shape(sheet, sheet.Width, sheet.Size);
    }
    bool EnsureVisibleSheets()
    {
        if (columns.Count == 0 || ActualWidth <= 0 || ActualHeight <= 0) return false;
        // Let the first decode and XAML image upload complete before the
        // high-priority animation queue constructs the rest of a dense rack.
        if (imagesLoadedSinceBuild == 0 && sheets.Count >= 8 && sheets.Any(s => s.Loading))
        { awaitingFirstImage = true; return false; }
        var view = RhineGeometry.View((float)pan.Value);
        var (first, last) = RhineGeometry.CandidateRows(view, (float)ActualWidth, (float)ActualHeight, rows, (float)dragY.Value);
        var pending = new List<(int Lane, int Row, bool HasImage, float Distance)>();
        var focus = new Vector2((float)ActualWidth / 2, (float)ActualHeight / 2);
        for (var lane = -2; lane <= 2; lane++)
            for (var row = first; row <= last; row++)
            {
                if (realized.ContainsKey((lane, row))) continue;
                var hasImage = row >= 0 && row < columns[lane].Length;
                // The macOS archive keeps a long translucent tail behind sparse
                // columns. It is a large part of the Rhine silhouette, especially
                // on the empty right side of the scene.
                var blankTail = Math.Max(0, 52 - columns[lane].Length);
                if (!hasImage && (row < -2 || row > columns[lane].Length + blankTail)) continue;
                var depth = RhineGeometry.Depth(row,lane);
                var h = RhineGeometry.Height(lane, depth, crest.Value, across.Value);
                var position = new Vector3(lane * (lane < 0 ? 5.65f : 6.25f), (float)h, (float)depth - 5);
                var matrix = RhineGeometry.Plane(position, Quaternion.Identity, view, (float)ActualWidth, (float)ActualHeight);
                var center = Vector2.Transform(Vector2.Zero, matrix) + new Vector2((float)dragX.Value, (float)dragY.Value);
                var extentX = (Math.Abs(matrix.M11) * 535 + Math.Abs(matrix.M21) * 650) / 2;
                var extentY = (Math.Abs(matrix.M12) * 535 + Math.Abs(matrix.M22) * 650) / 2;
                if (center.X + extentX > -160 && center.X - extentX < ActualWidth + 160 &&
                    center.Y + extentY > -160 && center.Y - extentY < ActualHeight + 160)
                    pending.Add((lane, row, hasImage, Vector2.DistanceSquared(center, focus)));
            }
        // Each sheet creates several XAML and Composition elements. Materialize
        // the front of the rack first, in small UI turns, instead of blocking a
        // date switch for the full wall (about 1.9 s with 197 sheets at 1280 px).
        pending.Sort((a, b) => a.HasImage == b.HasImage ? a.Distance.CompareTo(b.Distance) : a.HasImage ? -1 : 1);
        var started = Stopwatch.GetTimestamp();
        var created = 0;
        var turnLimit = reduced ? 8 : 2;
        while (created < Math.Min(turnLimit, pending.Count))
        {
            if (created > 0 && (Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency >= 3) break;
            EnsureSheet(pending[created].Lane, pending[created].Row);
            created++;
        }
        return pending.Count > created;
    }
    const int WallImageEdge = 320, ExpandedImageEdge = 1200;
    const long MaxRetainedImageBytes = 160_000_000;
    static long EstimatedBytes(int edge) => (long)edge * edge * 5 / 2;
    static long BitmapBytes(BitmapImage? bitmap) => bitmap is null ? 0 : (long)bitmap.PixelWidth * bitmap.PixelHeight * 4;
    static long ImageBytes(Sheet sheet) => BitmapBytes(sheet.Image?.Source as BitmapImage) + BitmapBytes(sheet.PendingImage);
    bool CanRetainImage(Sheet sheet, BitmapImage bitmap) =>
        sheets.Sum(ImageBytes) - (DeferringImages ? BitmapBytes(sheet.PendingImage) : ImageBytes(sheet)) + BitmapBytes(bitmap) <= MaxRetainedImageBytes;
    bool NearViewport(Sheet sheet, double margin)
    {
        var center = Vector2.Transform(Vector2.Zero, sheet.Matrix);
        var extentX = (Math.Abs(sheet.Matrix.M11) * sheet.Width + Math.Abs(sheet.Matrix.M21) * sheet.Size) / 2;
        var extentY = (Math.Abs(sheet.Matrix.M12) * sheet.Width + Math.Abs(sheet.Matrix.M22) * sheet.Size) / 2;
        return center.X + extentX > -margin && center.X - extentX < ActualWidth + margin &&
            center.Y + extentY > -margin && center.Y - extentY < ActualHeight + margin;
    }
    bool PruneSheets()
    {
        foreach (var sheet in sheets)
            if (sheet != extracted && sheet != hovered && !sheet.Loading &&
                (sheet.Image?.Source != null || sheet.PendingImage != null) &&
                sheet.Root.Visibility == Visibility.Collapsed && !NearViewport(sheet, 220))
            { if (sheet.Image != null) sheet.Image.Source = null; sheet.ImageEdge = 0; sheet.PendingImage = null; sheet.PendingEdge = 0; releasedImages++; }
        var retained = Math.Max(80, sheets.Count(s => NearViewport(s, 220)) + 24);
        if (sheets.Count <= retained) return false;
        var victims = sheets.Where(s => s != extracted && s != hovered && !s.Loading && !NearViewport(s, 220))
            .OrderByDescending(s => Math.Abs(s.Depth - pan.Value)).Take(8).ToArray();
        foreach (var sheet in victims)
        {
            if (sheet.Image != null) sheet.Image.Source = null;
            sheet.ImageEdge = 0; sheet.PendingImage = null; sheet.PendingEdge = 0;
            wall.Children.Remove(sheet.Root);
            sheets.Remove(sheet); drawOrder.Remove(sheet); realized.Remove((sheet.Lane, sheet.Row));
            evictedSheets++; orderDirty = true;
        }
        return victims.Length > 0 && sheets.Count > retained;
    }
    static ImageBrush CreateGlass(int lane)
    {
        // Like SceneKit's glassTexture, rasterize once per lane and reuse the
        // texture across the rack. Avoid re-rasterizing translucent gradients.
        const int height = 320;
        var bitmap = new WriteableBitmap(1,height);
        float[] offsets = [0,.65f,.95f,1];
        var pixels = new byte[height*4];
        for (var y = 0; y < height; y++)
        {
            var p = 1-y/(float)(height-1); var stop = 0;
            while (stop < 2 && p > offsets[stop+1]) stop++;
            var c = Vector4.Lerp(RhineTone.Stop(lane,stop,Design.Dark),RhineTone.Stop(lane,stop+1,Design.Dark),(p-offsets[stop])/(offsets[stop+1]-offsets[stop]));
            pixels[y*4] = (byte)(c.Z*c.W*255); pixels[y*4+1] = (byte)(c.Y*c.W*255);
            pixels[y*4+2] = (byte)(c.X*c.W*255); pixels[y*4+3] = (byte)(c.W*255);
        }
        using (var stream = bitmap.PixelBuffer.AsStream()) stream.Write(pixels);
        bitmap.Invalidate();
        return new ImageBrush { ImageSource = bitmap, Stretch = Stretch.Fill };
    }
    void QueueImagePump()
    {
        if (Interlocked.Exchange(ref imagePumpQueued, 1) != 0) return;
        if (!uiQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Normal, () =>
        {
            Volatile.Write(ref imagePumpQueued, 0);
            PumpImages();
        }))
        {
            Volatile.Write(ref imagePumpQueued, 0);
            if (active) imageTimer.Start();
        }
    }
    void PumpImages()
    {
        if (!active) { imageTimer.Stop(); return; }
        // Do not enqueue decoding/upload work during a return or an active drag.
        if (pointerDown || DeferringImages) return;
        pendingImages.Clear(); var loading = 0; long reserved = 0;
        var focus = new Vector2((float)ActualWidth/2,(float)ActualHeight/2);
        foreach (var s in sheets)
        {
            if (s.Loading) { loading++; reserved += EstimatedBytes(s.LoadingEdge); continue; }
            if (s.Frame == null || s.Failed) continue;
            var edge = s == extracted ? ExpandedImageEdge : WallImageEdge;
            if (s.Image?.Source != null && s.ImageEdge == edge || s.PendingImage != null && s.PendingEdge == edge) continue;
            if (s != extracted && !NearViewport(s, 180)) continue;
            var width = MathF.Sqrt(s.Matrix.M11*s.Matrix.M11+s.Matrix.M12*s.Matrix.M12) * 495;
            var height = MathF.Sqrt(s.Matrix.M21*s.Matrix.M21+s.Matrix.M22*s.Matrix.M22) * 309.375f;
            // A sub-20px card is glass texture, not a useful photograph.
            if (s != extracted && (width < 20 || height < 13)) continue;
            var center = Vector2.Transform(new Vector2(0,-150),s.Matrix);
            var normalizedDistance = Vector2.DistanceSquared(center,focus) /
                Math.Max(1,ActualWidth*ActualWidth+ActualHeight*ActualHeight);
            var priority = s == extracted ? -1000 : (s.Root.Visibility == Visibility.Visible ? 0 : 5)
                + normalizedDistance + Math.Max(0,s.Distance-25)*.025f - MathF.Min(1,width/500)*.25f;
            pendingImages.Add((s,edge,(float)priority));
        }
        if (pendingImages.Count == 0 || loading >= MaxImageRequests) { imageTimer.Stop(); return; }
        pendingImages.Sort((a,b) => a.Priority.CompareTo(b.Priority));
        var retained = sheets.Sum(ImageBytes);
        var needed = EstimatedBytes(pendingImages[0].Edge);
        if (retained + reserved + needed > MaxRetainedImageBytes)
        {
            foreach (var victim in sheets.Where(s => s != extracted && s != hovered && !s.Loading &&
                         (s.Image?.Source != null || s.PendingImage != null) && !NearViewport(s,180))
                     .OrderByDescending(s => Math.Abs(s.Depth-pan.Value)))
            {
                retained -= ImageBytes(victim); if (victim.Image != null) victim.Image.Source = null;
                victim.ImageEdge = 0; victim.PendingImage = null; victim.PendingEdge = 0; releasedImages++;
                if (retained + reserved + needed <= MaxRetainedImageBytes) break;
            }
        }
        var started = 0;
        foreach (var request in pendingImages)
        {
            if (started >= MaxImageRequests-loading) break;
            var estimate = EstimatedBytes(request.Edge);
            if (retained + reserved + estimate > MaxRetainedImageBytes) continue;
            Load(request.Sheet,request.Edge); reserved += estimate; started++;
        }
        // A completion immediately schedules the next normal-priority pump.
        // The timer is only a fallback for newly materialized/visible sheets.
        imageTimer.Stop();
    }
    void BeginTransition(string direction)
    {
        transitionStarted = Stopwatch.GetTimestamp(); transitionDirection = direction;
        transitionFrames = transitionSlowFrames = transitionClockTicks = matrixWrites = imageRequests = 0;
        transitionMaxUpdateMs = transitionMaxIntervalMs = transitionMaxQueueMs = transitionMaxClockIntervalMs = lastTransitionMs = 0;
        Interlocked.Exchange(ref lastClockTick, 0);
    }
    static void Shape(Sheet s, float width, float height)
    {
        var aspect = s.ExpandedAspect;
        if (Math.Abs(s.Width-width) < .01f && Math.Abs(s.Size-height) < .01f &&
            Math.Abs(s.ShapedAspect-aspect) < .0001f &&
            Math.Abs(s.ShapedFooterRasterScale-s.FooterRasterScale) < .001f) return;
        // Glass, image and the entire information/action footer share one
        // root matrix. Scaling the footer uniformly keeps text/buttons in plane.
        s.Width = width; s.Size = height;
        s.ShapedAspect = aspect;
        s.ShapedFooterRasterScale = s.FooterRasterScale;
        var layout = s.Layout = RhineGeometry.Layout(width, height, aspect);
        static void Transform(Visual v, float x, float y, float sx, float sy)
        { v.TransformMatrix = Matrix4x4.CreateScale(sx, sy, 1) * Matrix4x4.CreateTranslation(x, y, 0); }
        Transform(s.GlassVisual, -width / 2, -height / 2, width / 535, height / 650);
        if (s.DepthFogVisual != null) Transform(s.DepthFogVisual, -width / 2, -height / 2, width / 535, height / 650);
        if (s.FocusVisual != null) Transform(s.FocusVisual, -width / 2, -height / 2, width / 535, height / 650);
        if (s.ArtVisual != null) Transform(s.ArtVisual, layout.ArtLeft, layout.ArtTop, layout.FooterScale, layout.FooterScale);
        if (s.FooterVisual != null) Transform(s.FooterVisual, layout.ArtLeft, layout.FooterTop,
            layout.FooterScale / s.FooterRasterScale, layout.FooterScale / s.FooterRasterScale);
    }
    static readonly string[] actionNames = ["Star", "Copy text", "Rewind", "Collapse"];
    static readonly string[] actionSymbols = ["\uE734", "\uE8C8", "\uE8A7", "\uE8B6"];
    void CreateProjectedActions(Sheet sheet)
    {
        if (sheet.Footer == null || sheet.Actions != null) return;
        var row = new Grid { Height = 26, VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new(8,0,8,4), ColumnSpacing = 7, IsHitTestVisible = false };
        var borders = new Border[4];
        var labels = new TextBlock[4];
        var symbols = new FontIcon[4];
        var contentsRows = new StackPanel[4];
        for (var i = 0; i < borders.Length; i++)
        {
            row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            var label = Design.Text(i == 0 && sheet.Frame?.Starred == true ? "Starred" : actionNames[i], 13);
            label.TextWrapping = TextWrapping.NoWrap; label.TextTrimming = TextTrimming.CharacterEllipsis;
            var symbol = new FontIcon { Glyph = actionSymbols[i], FontFamily = new("Segoe Fluent Icons"), FontSize = 15,
                Foreground = Design.Brush(Design.Ink) };
            labels[i] = label; symbols[i] = symbol;
            var contents = Design.Row(6, symbol, label);
            contentsRows[i] = contents;
            contents.HorizontalAlignment = HorizontalAlignment.Center;
            borders[i] = new Border { Child = contents, CornerRadius = new(10), BorderThickness = new(1),
                BorderBrush = Design.RimBrush,
                Background = Design.Brush(Design.Dark ? Color.FromArgb(42,230,240,255) : Color.FromArgb(195,255,255,255)) };
            if (i == 0) sheet.StarLabel = label;
            Grid.SetColumn(borders[i],i); row.Children.Add(borders[i]);
        }
        // The dimming fog covers the complete footer, including these actions.
        sheet.Footer.Children.Insert(Math.Max(0,sheet.Footer.Children.Count-1), row);
        sheet.Actions = row; sheet.ActionBorders = borders; sheet.ActionLabels = labels; sheet.ActionSymbols = symbols;
        sheet.ActionContents = contentsRows;
        sheet.ActionVisual = ElementCompositionPreview.GetElementVisual(row);
        sheet.ActionVisual.Opacity = 0; sheet.ActionOpacity = 0;
    }
    static void RemoveProjectedActions(Sheet sheet)
    {
        if (sheet.Actions != null && sheet.Footer != null) sheet.Footer.Children.Remove(sheet.Actions);
        sheet.Actions = null; sheet.ActionBorders = null; sheet.ActionLabels = null; sheet.ActionSymbols = null;
        sheet.ActionContents = null; sheet.StarLabel = null;
        sheet.ActionVisual = null; sheet.ActionOpacity = -1;
    }
    void SetActionFocus(int index, bool focused)
    {
        if (extracted?.ActionBorders is not { } borders || index >= borders.Length) return;
        borders[index].BorderBrush = focused ? Design.Brush(Design.Blue) : Design.RimBrush;
        borders[index].BorderThickness = new((focused ? 2 : 1) * extracted.FooterRasterScale);
        if (frontCopy?.ActionBorders is { } copyBorders)
        { copyBorders[index].BorderBrush = borders[index].BorderBrush; copyBorders[index].BorderThickness = borders[index].BorderThickness; }
    }
    bool DeferringImages => pointerDown || transitionStarted != 0 || extracted != null && !extraction.Settled(extractTarget);
    void PresentImage(Sheet sheet, BitmapImage bitmap, int edge)
    {
        if (sheet.Image == null) return;
        sheet.PendingImage = null; sheet.PendingEdge = 0;
        sheet.Image.Source = bitmap; sheet.ImageEdge = edge;
        if (sheet == extracted && frontCopy?.Image != null) frontCopy.Image.Source = bitmap;
        if (sheet != extracted && bitmap.PixelWidth > 0 && bitmap.PixelHeight > 0)
        {
            var aspect = Math.Clamp((float)bitmap.PixelWidth / bitmap.PixelHeight, .2f, 5);
            if (Math.Abs(sheet.Aspect-aspect) > .001f)
            {
                sheet.Aspect = sheet.ExpandedAspect = aspect;
                sheet.Image.Height = sheet.Art!.Height = RhineGeometry.ArtBaseWidth / aspect;
                Shape(sheet, sheet.Width, sheet.Size);
            }
        }
        if (imagesLoadedSinceBuild++ == 0 && buildEndedAt != 0)
            firstImageMs = (Stopwatch.GetTimestamp() - buildEndedAt) * 1000.0 / Stopwatch.Frequency;
        // A loaded screenshot needs an opaque backing, including in dark mode.
        if (sheet.Art != null)
        {
            var backing = Design.Brush(Design.Dark ? Color.FromArgb(255,15,18,24) : Color.FromArgb(255,230,228,221));
            sheet.Art.Background = backing;
            if (sheet == extracted && frontCopy?.Art != null) frontCopy.Art.Background = backing;
        }
    }
    void QueuePendingFlush()
    {
        if (!active || DeferringImages || Interlocked.Exchange(ref pendingFlushQueued, 1) != 0) return;
        if (!uiQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            Volatile.Write(ref pendingFlushQueued, 0);
            FlushPendingImages();
        })) Volatile.Write(ref pendingFlushQueued, 0);
    }
    void FlushPendingImages()
    {
        if (!active || DeferringImages) return;
        var committed = 0;
        foreach (var sheet in sheets.OrderByDescending(s => s == extracted ? 3 : s.Root.Visibility == Visibility.Visible ? 2 : 1))
        {
            if (sheet.PendingImage is not { } bitmap) continue;
            var edge = sheet.PendingEdge;
            if (!realized.TryGetValue((sheet.Lane, sheet.Row), out var current) || !ReferenceEquals(current, sheet) ||
                edge == ExpandedImageEdge && sheet != extracted || sheet != extracted && !NearViewport(sheet,220))
            { sheet.PendingImage = null; sheet.PendingEdge = 0; continue; }
            PresentImage(sheet, bitmap, edge);
            if (++committed == 2) break;
        }
        if (sheets.Any(s => s.PendingImage != null)) QueuePendingFlush();
        else imageTimer.Start();
    }
    async void Load(Sheet sheet, int edge)
    {
        if (sheet.Loading || sheet.Failed || sheet.Frame == null || sheet.Image == null ||
            sheet.Image.Source != null && sheet.ImageEdge == edge || sheet.PendingImage != null && sheet.PendingEdge == edge) return;
        sheet.Loading = true; sheet.LoadingEdge = edge; if (transitionStarted != 0) imageRequests++;
        var loadSerial = ++sheet.LoadSerial;
        var started = Stopwatch.GetTimestamp();
        var token = imageLoads.Token;
        var imagePath = sheet.Frame.ImagePath;
        try
        {
            var bitmap = await MemoryImages.Load(runtime.Store, imagePath, edge, token);
            if (loadSerial == sheet.LoadSerial && !token.IsCancellationRequested &&
                realized.TryGetValue((sheet.Lane, sheet.Row), out var current) &&
                ReferenceEquals(current, sheet) && (sheet == extracted || NearViewport(sheet,220)) &&
                StringComparer.Ordinal.Equals(sheet.Frame?.ImagePath,imagePath) &&
                (edge != ExpandedImageEdge || sheet == extracted) &&
                CanRetainImage(sheet,bitmap))
            {
                var loadMs = (Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency;
                imageLoadTotalMs += loadMs; maxImageLoadMs = Math.Max(maxImageLoadMs, loadMs);
                if (DeferringImages)
                { sheet.PendingImage = bitmap; sheet.PendingEdge = edge; }
                else PresentImage(sheet, bitmap, edge);
            }
        }
        catch (OperationCanceledException) { }
        catch { if (loadSerial == sheet.LoadSerial) sheet.Failed = true; /* Do not retry failed I/O every animation tick. */ }
        finally
        {
            if (loadSerial == sheet.LoadSerial)
            {
                sheet.Loading = false; sheet.LoadingEdge = 0;
                if (active && !token.IsCancellationRequested &&
                    realized.TryGetValue((sheet.Lane, sheet.Row), out var current) && ReferenceEquals(current, sheet))
                    QueueImagePump();
                if (awaitingFirstImage && active && !token.IsCancellationRequested)
                { awaitingFirstImage = false; Wake(); }
            }
        }
    }
    void Move(Point point)
    {
        pointerMoves++;
        if (extracted != null) return;
        var hit = Pick(point, out _);
        if (hovered == hit) return;
        hovered = hit; hoverChanges++; UpdateCaption();
        if (hit != null) { acrossTarget = hit.Lane; crestTarget = hit.Depth; Wake(); }
    }
    Sheet? Pick(Point point, out Vector2 local)
    {
        if (extracted != null && RhineGeometry.Hit(extracted.Matrix, new((float)point.X, (float)point.Y), extracted.Width, extracted.Size, out local)) return extracted;
        local = default; Sheet? best = null; var distance = float.MaxValue;
        foreach (var s in sheets)
        {
            if (s.Frame == null || s.Distance > distance || s.Root.Visibility != Visibility.Visible) continue;
            if (!RhineGeometry.Hit(s.Matrix, new((float)point.X, (float)point.Y), s.Width, s.Size, out var p)) continue;
            distance = s.Distance; best = s; local = p;
        }
        return best;
    }
    void Expand(Sheet sheet)
    {
        if (extracted != null && extracted != sheet) return;
        expansions++;
        sheet.FocusVisual!.Opacity = RhineGeometry.Smooth(((float)extraction.Value-.12f)/.78f);
        if (!sheet.GlassAttached) { GlassMaterial.Attach(sheet.FocusGlass!, 2, desktopSurface: false); sheet.GlassAttached = true; }
        extractedTitle.Text = sheet.Frame?.Title ?? "";
        extractedDate.Text = sheet.Frame?.Timestamp.LocalDateTime.ToString("MMM d · HH:mm") ?? "";
        starAction.Content = Design.Text(sheet.Frame?.Starred == true ? "Starred" : "Star", 13);
        AutomationProperties.SetName(starAction, sheet.Frame?.Starred == true ? "Starred" : "Star");
        sheet.ExpandedAspect = sheet.Aspect;
        CreateProjectedActions(sheet);
        var (openWidth, openHeight) = RhineGeometry.ExpandedSize(sheet.ExpandedAspect,
            (float)ActualWidth, (float)ActualHeight, expandedTopInset, expandedBottomInset);
        var view = RhineGeometry.View((float)pan.Value);
        Matrix4x4.Invert(view, out var camera);
        var destination = Vector3.Transform(new Vector3(0,0,-14), camera);
        var finalMatrix = RhineGeometry.Plane(destination, Quaternion.CreateFromRotationMatrix(camera), view,
            (float)ActualWidth, (float)ActualHeight);
        var finalScale = RhineGeometry.FooterScreenScale(
            RhineGeometry.Layout(openWidth, openHeight, sheet.ExpandedAspect), finalMatrix);
        // A harness may request a card before its first measured viewport.
        // Never divide by a near-zero projection to create giant XAML glyphs;
        // SizeChanged will establish the final 18/14/16 DIP raster once ready.
        if (ActualWidth >= 100 && ActualHeight >= 100 && finalScale >= .05f && float.IsFinite(finalScale))
            SetFooterRaster(sheet, Math.Max(1, finalScale), finalScale, true);
        else SetFooterRaster(sheet, 1, 1, false);
        sheet.Footer?.UpdateLayout();
        CreateFrontCopy(sheet);
        // Complete the one-time XAML layout before starting the 620 ms clock.
        // Otherwise the first render can include a full duplicate card layout.
        BeginTransition("open");
        extracted = sheet; extractTarget = 1; hovered = null; orderDirty = true; ExpansionChanged?.Invoke(true); UpdateCaption(); imageTimer.Start(); Wake();
    }
    public void Open(string id)
    {
        var request = ++seekRevision;
        var sheet = sheets.FirstOrDefault(s => s.Frame?.Id == id);
        if (sheet != null) { Expand(sheet); return; }
        _ = OpenFromStore(id,request);
    }
    async Task OpenFromStore(string id, int request)
    {
        var frame = await Task.Run(() => runtime.Store.Frame(id));
        if (active && request == seekRevision && frame != null) Seek(frame, expand: true);
    }
    public void Collapse() { if (extracted == null || extractTarget == 0) return; collapses++; BeginTransition("close"); extractTarget = 0; SetExpandedControlsVisible(false); Wake(); }
    async void Act(int index)
    {
        if (extracted?.Frame is not { } frame) return;
        if (index == 0)
        {
            var sheet = extracted;
            await Task.Run(() => runtime.Store.Star(frame.Id));
            if (extracted != sheet || sheet.Frame?.Id != frame.Id) return;
            sheet.Frame = frame with { Starred = !frame.Starred };
            var label = sheet.Frame.Starred ? "Starred" : "Star";
            starAction.Content = Design.Text(label, 13);
            AutomationProperties.SetName(starAction, label);
            if (sheet.StarLabel != null) sheet.StarLabel.Text = label;
            if (frontCopy?.StarLabel != null) frontCopy.StarLabel.Text = label;
            var recordIndex = records.FindIndex(item => item.Id == frame.Id);
            if (recordIndex >= 0) records[recordIndex] = sheet.Frame;
            var column = columns[sheet.Lane];
            if (sheet.Row >= 0 && sheet.Row < column.Length) column[sheet.Row] = sheet.Frame;
        }
        else if (index == 1)
        {
            var full = await Task.Run(() => runtime.Store.Frame(frame.Id));
            if (full != null && extracted?.Frame?.Id == frame.Id)
            { var data = new DataPackage(); data.SetText(full.Text); Clipboard.SetContent(data); }
        }
        else if (index == 2)
        {
            var full = await Task.Run(() => runtime.Store.Frame(frame.Id));
            if (full != null && extracted?.Frame?.Id == frame.Id) rewind(full);
        }
        else Collapse();
    }
    void UpdateCaption()
    {
        UpdateStatus();
        caption.Visibility = !timeline && hovered?.Frame != null && extracted == null ? Visibility.Visible : Visibility.Collapsed;
        captionText.Text = hovered?.Frame?.Timestamp.LocalDateTime.ToString("MMM d · HH:mm") ?? "";
    }
    void Wake()
    {
        if (!active || ticking) return;
        previous = Stopwatch.GetTimestamp(); ticking = true; motionClock.Change(0,16);
    }
    void SetExpandedControlsVisible(bool visible)
    {
        // The visible actions always remain on the depth-sorted card. This
        // invisible overlay is a real input/UIA surface only at the final pose.
        var buttonsEnabled = visible;
        if (extractedButtonsEnabled != buttonsEnabled)
        {
            extractedButtonsEnabled = buttonsEnabled;
            foreach (var button in extractedActionButtons) button.IsEnabled = buttonsEnabled;
        }
        if (expandedControlsShown == visible) return;
        if (!visible) Focus(FocusState.Programmatic);
        expandedControlsShown = visible;
        extractedAutomation.ExposeChildren = visible;
        extractedAutomation.IsHitTestVisible = visible;
        extractedControls.IsHitTestVisible = visible;
        AutomationProperties.SetName(this, visible && extracted?.Frame is { } frame
            ? $"Rhine archive, {frame.Title}, {frame.Timestamp.LocalDateTime:MMM d · HH:mm}, expanded"
            : $"Rhine archive, {day:MMMM d, yyyy}");
        var view = visible ? AccessibilityView.Content : AccessibilityView.Raw;
        AutomationProperties.SetAccessibilityView(extractedControls, view);
        AutomationProperties.SetAccessibilityView(extractedTitle, view);
        AutomationProperties.SetAccessibilityView(extractedDate, view);
        foreach (var button in extractedActionButtons)
        {
            button.IsTabStop = visible;
            AutomationProperties.SetAccessibilityView(button, view);
        }
    }
    void QueueFrame()
    {
        var now = Stopwatch.GetTimestamp();
        var last = Interlocked.Exchange(ref lastClockTick, now);
        if (transitionStarted != 0)
        {
            Interlocked.Increment(ref transitionClockTicks);
            if (last != 0) transitionMaxClockIntervalMs = Math.Max(transitionMaxClockIntervalMs, (now-last)*1000.0/Stopwatch.Frequency);
        }
        if (Interlocked.Exchange(ref frameQueued,1) != 0) return;
        Volatile.Write(ref frameQueuedAt, now);
        if (!uiQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.High, () =>
        {
            var queuedAt = Volatile.Read(ref frameQueuedAt);
            Volatile.Write(ref frameQueued,0);
            if (transitionStarted != 0 && queuedAt != 0)
                transitionMaxQueueMs = Math.Max(transitionMaxQueueMs,(Stopwatch.GetTimestamp()-queuedAt)*1000.0/Stopwatch.Frequency);
            if (ticking) Render(null,EventArgs.Empty);
        })) Volatile.Write(ref frameQueued,0);
    }
    void Stop() { motionClock.Change(Timeout.Infinite,Timeout.Infinite); ticking = false; }
    void Render(object? sender, object args)
    {
        if (ActualWidth <= 0 || ActualHeight <= 0) return;
        var now = Stopwatch.GetTimestamp(); var interval = (now-previous)*1000.0/Stopwatch.Frequency;
        var dt = Math.Clamp(interval/1000, 1.0/240, 1); previous = now;
        var profiling = transitionStarted != 0;
        if (profiling) { transitionFrames++; transitionMaxIntervalMs = Math.Max(transitionMaxIntervalMs,interval); if (interval > 50) transitionSlowFrames++; }
        if (reduced) { crest = new(crestTarget); across = new(acrossTarget); pan = new(panTarget); extraction = new(extractTarget); }
        else { crest.Step(crestTarget, 8, dt); across.Step(acrossTarget, 7, dt); pan.Step(panTarget, 10, dt); extraction.Step(extractTarget, dt); }
        bool sceneMoving = !crest.Settled(crestTarget) || !across.Settled(acrossTarget) || !pan.Settled(panTarget);
        bool moving = sceneMoving || !extraction.Settled(extractTarget);
        if (reduced) { dragX = new(dragTargetX); dragY = new(dragTargetY); } else { dragX.Step(dragTargetX,24,dt); dragY.Step(dragTargetY,24,dt); }
        sceneMoving |= !dragX.Settled(dragTargetX) || !dragY.Settled(dragTargetY);
        moving |= sceneMoving;
        // Complete before rendering: footer, depth order, input and toolbar all
        // observe the same final pose rather than changing on a later timer tick.
        if (extracted != null && extractTarget == 0 && extraction.Settled(0))
        {
            var returned = extracted;
            ReleaseFrontCopy();
            SetFooterRaster(returned, 1, 1, false);
            returned.FocusVisual!.Opacity = 0;
            RemoveProjectedActions(returned);
            returned.ExpandedAspect = returned.Aspect;
            Shape(returned,535,650); extracted = null; orderDirty = true; imageTimer.Start();
            ExpansionChanged?.Invoke(false); UpdateCaption();
        }
        moving |= EnsureVisibleSheets();
        var view = RhineGeometry.View((float)pan.Value); Matrix4x4.Invert(view, out var camera);
        var cameraRotation = Quaternion.CreateFromRotationMatrix(camera);
        var span = 19.98f * (float)(ActualHeight / ActualWidth);
        var refreshScene = sceneMoving || orderDirty;
        var depthChanged = false;
        foreach (var s in sheets)
        {
            var wanted = RhineGeometry.Height(s.Lane, s.Depth, crest.Value, across.Value);
            if (s != extracted && !refreshScene && s.Height.Settled(wanted)) continue;
            var previousHeight = s.Height.Value;
            if (reduced) s.Height = new(wanted); else s.Height.Step(wanted, 9 - Math.Abs(s.Lane) * .9, dt);
            moving |= !s.Height.Settled(wanted);
            depthChanged |= s != extracted && Math.Abs(s.Height.Value - previousHeight) > .0001;
            var rotation = Quaternion.Identity;
            s.Position = new(s.Lane * (s.Lane < 0 ? 5.65f : 6.25f), (float)s.Height.Value, (float)s.Depth - 5);
            var homeDistance = -Vector3.Transform(s.Position,view).Z;
            if (s == extracted)
            {
                var p = (float)Math.Clamp(extraction.Value, 0, 1);
                var destination = Vector3.Transform(new Vector3(0, 0, -14), camera);
                s.Position = RhineGeometry.Extract(s.Position, destination, p);
                rotation = Quaternion.Slerp(Quaternion.Identity, cameraRotation, RhineGeometry.Smooth((p - .3f) / .65f));
                var (openWidth, openHeight) = RhineGeometry.ExpandedSize(s.ExpandedAspect,
                    (float)ActualWidth, (float)ActualHeight, expandedTopInset, expandedBottomInset);
                var t = RhineGeometry.Smooth((p - .3f) / .7f);
                Shape(s, 535 + (openWidth - 535) * t, 650 + (openHeight - 650) * t);
                s.FocusVisual!.Opacity = t;
                var actionOpacity = RhineGeometry.ActionBlend(p);
                if (s.ActionVisual != null && Math.Abs(s.ActionOpacity-actionOpacity) > .002f)
                { s.ActionVisual.Opacity = actionOpacity; s.ActionOpacity = actionOpacity; }
            }
            var matrix = RhineGeometry.Plane(s.Position, rotation, view, (float)ActualWidth, (float)ActualHeight);
            var shift = s == extracted ? 1 - Math.Clamp(extraction.Value,0,1) : 1;
            matrix.M31 += (float)(dragX.Value * shift); matrix.M32 += (float)(dragY.Value * shift);
            if (s == extracted)
                matrix.M32 += RhineGeometry.ExpandedCenterShift(expandedTopInset, expandedBottomInset) *
                    RhineGeometry.Smooth(((float)extraction.Value - .3f) / .7f);
            if (s == extracted && extractTarget == 1 && extraction.Settled(1))
                matrix = RhineGeometry.SnapFacingPlane(matrix, s.Layout, (float)(XamlRoot?.RasterizationScale ?? 1));
            if (matrix != s.Matrix) { s.Matrix = matrix; s.Visual.TransformMatrix = RhineGeometry.Matrix(matrix); matrixWrites++; }
            var previousSortDistance = s.SortDistance;
            s.Distance = -Vector3.Transform(s.Position, view).Z;
            s.SortDistance = s == extracted ? homeDistance : s.Distance;
            depthChanged |= Math.Abs(s.SortDistance - previousSortDistance) > .0001f;
            var center = Vector2.Transform(Vector2.Zero, s.Matrix);
            var extentX = (Math.Abs(s.Matrix.M11) * s.Width + Math.Abs(s.Matrix.M21) * s.Size) / 2;
            var extentY = (Math.Abs(s.Matrix.M12) * s.Width + Math.Abs(s.Matrix.M22) * s.Size) / 2;
            var visible = center.X + extentX > -80 && center.X - extentX < ActualWidth + 80 && center.Y + extentY > -80 && center.Y - extentY < ActualHeight + 80;
            var visibility = visible ? Visibility.Visible : Visibility.Collapsed;
            if (s.Root.Visibility != visibility) { s.Root.Visibility = visibility; if (visible && !imageTimer.IsRunning) imageTimer.Start(); }
            // SceneKit softens distant sheets, but it does not lay an opaque veil
            // over the near rack. Keep the neutral fog on the far side only so
            // actual screenshots and their footer remain legible at the crest.
            var blend = s == extracted ? (float)extraction.Value : 0;
            var farFog = Math.Clamp((s.Distance - 36f) / 13f, 0, .88f) * (1-blend);
            var sceneHaze = farFog * .78f;
            var depthFogOpacity = sceneHaze * (Design.Dark ? .46f : .52f);
            if (Math.Abs(s.DepthFogOpacity-depthFogOpacity) > .002f)
            { s.DepthFogVisual!.Opacity = depthFogOpacity; s.DepthFogOpacity = depthFogOpacity; }
            // RhineTone already contains macOS' material transparency folded
            // into each color stop. Present it at full strength here; applying
            // another partial opacity washed the empty right-hand rack white.
            var glassOpacity = (s.Frame == null ? 1f : .96f) * (1-sceneHaze*.45f) + blend*.04f;
            if (Math.Abs(s.GlassOpacity-glassOpacity) > .002f)
            { s.GlassVisual.Opacity = glassOpacity; s.GlassOpacity = glassOpacity; }
            if (s.Frame != null)
            {
                var fog = farFog;
                var imageOpacity = (Design.Dark ? .78f : 1) * (1-farFog*.10f);
                if (Math.Abs(s.ImageOpacity-imageOpacity) > .002) { s.ImageVisual!.Opacity = imageOpacity; s.ImageOpacity = imageOpacity; }
                if (Math.Abs(s.FogOpacity-fog) > .002) { s.FogVisual!.Opacity = fog; s.FogOpacity = fog; }
            }
            var opacity = Math.Clamp((60-s.Distance)/24,s.Frame == null ? .08f : .18f,1); opacity += (1-opacity)*blend;
            if (Math.Abs(s.DrawOpacity-opacity) > .002) { s.Visual.Opacity = opacity; s.DrawOpacity = opacity; }
        }
        foreach (var tag in dayTags.Values)
        {
            var position = new Vector3(tag.Lane * (tag.Lane < 0 ? 5.65f : 6.25f),
                (float)RhineGeometry.Height(tag.Lane,tag.Depth,crest.Value,across.Value)+3.65f-Math.Max(0,tag.Lane)*1.15f,
                tag.Depth-5);
            var matrix = RhineGeometry.Plane(position,cameraRotation,view,(float)ActualWidth,(float)ActualHeight);
            matrix.M31 += (float)dragX.Value; matrix.M32 += (float)dragY.Value;
            tag.Visual.TransformMatrix = RhineGeometry.Matrix(matrix);
            var point = Vector2.Transform(Vector2.Zero,matrix);
            tag.Root.Visibility = point.X > -280 && point.X < ActualWidth+280 && point.Y > -80 && point.Y < ActualHeight+80
                ? Visibility.Visible : Visibility.Collapsed;
            tag.Visual.Opacity = extracted == null ? .92f : .22f;
        }
        if (extracted is { } open)
        {
            SyncFrontCopy(open, (float)extraction.Value);
            var footerMatrix = RhineGeometry.FooterMatrix(open.Layout, open.Matrix);
            if (footerMatrix != inputMatrix)
            {
                inputMatrix = footerMatrix;
                extractedTransform.Matrix = new Microsoft.UI.Xaml.Media.Matrix(footerMatrix.M11, footerMatrix.M12,
                    footerMatrix.M21, footerMatrix.M22, footerMatrix.M31, footerMatrix.M32);
            }
            SetExpandedControlsVisible(extractTarget == 1 && extraction.Settled(1));
        }
        else SetExpandedControlsVisible(false);
        moving |= PruneSheets();
        // Depth values move every tick, but ZIndex changes only at crossings.
        if (!orderDirty && depthChanged)
            for (var i = 1; i < drawOrder.Count; i++)
                if (drawOrder[i-1].SortDistance < drawOrder[i].SortDistance) { orderDirty = true; break; }
        if (orderDirty)
        {
            drawOrder.Sort((a, b) => RhineGeometry.DepthOrder(a.SortDistance,b.SortDistance));
            for (var i = 0; i < drawOrder.Count; i++)
            {
                var z = i;
                if (drawOrder[i].ZIndex != z) { Canvas.SetZIndex(drawOrder[i].Root, z); drawOrder[i].ZIndex = z; }
            }
            orderDirty = false;
        }
        if (profiling)
        {
            transitionMaxUpdateMs = Math.Max(transitionMaxUpdateMs,(Stopwatch.GetTimestamp()-now)*1000.0/Stopwatch.Frequency);
            if (extraction.Settled(extractTarget)) { lastTransitionMs = (Stopwatch.GetTimestamp()-transitionStarted)*1000.0/Stopwatch.Frequency; transitionStarted = 0; }
        }
        if (!DeferringImages && sheets.Any(s => s.PendingImage != null)) QueuePendingFlush();
        if (!moving) Stop();
    }
}
