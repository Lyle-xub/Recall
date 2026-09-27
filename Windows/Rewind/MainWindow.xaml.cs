using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Button=System.Windows.Controls.Button;
using TextBox=System.Windows.Controls.TextBox;
using Clipboard=System.Windows.Clipboard;
using MessageBox=System.Windows.MessageBox;
using Brush=System.Windows.Media.Brush;
using Color=System.Windows.Media.Color;
using Application=System.Windows.Application;
namespace Rewind;
public partial class MainWindow : Window {
    internal readonly MemoryStore Store;
    internal AppSettings Settings;
    private readonly CaptureService capture;
    private readonly DispatcherTimer searchTimer=new(){Interval=TimeSpan.FromMilliseconds(180)};
    private readonly DispatcherTimer toastTimer=new(){Interval=TimeSpan.FromSeconds(3)};
    private readonly System.Windows.Forms.NotifyIcon tray;
    private List<MemoryFrame> frames=[];
    private List<MemoryFrame> timeline=[];
    private MemoryFrame? selected;
    private List<TranscriptLine> transcript=[];
    private readonly List<ChatMessage> messages=[];
    private int visibilityGeneration;
    private bool resettingChat;
    private bool demo,trash,starred,meetingView,ready,quitting,transitioning;
    private string? appFilter;
    private DateTimeOffset? since;
    private CancellationTokenSource? chatCancellation;
    private readonly string settingsFile;
    [DllImport("user32.dll")]private static extern bool RegisterHotKey(IntPtr hWnd,int id,uint modifiers,uint key);
    [DllImport("user32.dll")]private static extern bool UnregisterHotKey(IntPtr hWnd,int id);
    [DllImport("user32.dll")]private static extern bool SetWindowDisplayAffinity(IntPtr hWnd,uint affinity);
    public MainWindow(bool demoMode=false) {
        InitializeComponent();Store=new(App.DataRoot);settingsFile=Path.Combine(App.DataRoot,"settings.json");
        Settings=File.Exists(settingsFile)?JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(settingsFile))??new():new();
        capture=new(Store);capture.FrameAdded+=_=>Dispatcher.BeginInvoke(Reload);capture.Error+=text=>Dispatcher.BeginInvoke(()=>{Notify(text);Reload();});
        capture.SegmentFinished+=s=>Dispatcher.BeginInvoke(async()=>await Transcribe(s));
        Store.Retain(Settings.RetentionDays);searchTimer.Tick+=(_,_)=>{searchTimer.Stop();Reload();};toastTimer.Tick+=(_,_)=>{Toast.Visibility=Visibility.Collapsed;toastTimer.Stop();};
        tray=new(){Icon=System.Drawing.SystemIcons.Application,Visible=true,Text="Rewind Replica · Paused"};
        var menu=new System.Windows.Forms.ContextMenuStrip();menu.Items.Add("Open Rewind",null,(_,_)=>Dispatcher.Invoke(ShowRewind));menu.Items.Add("Start / pause recording",null,(_,_)=>Dispatcher.Invoke(async()=>await ToggleRecording()));menu.Items.Add("Settings…",null,(_,_)=>Dispatcher.Invoke(OpenSettings));menu.Items.Add("Quit",null,(_,_)=>Dispatcher.Invoke(async()=>await Quit()));tray.ContextMenuStrip=menu;tray.DoubleClick+=(_,_)=>Dispatcher.Invoke(ShowRewind);
        SourceInitialized+=(_,_)=>{var handle=new WindowInteropHelper(this).Handle;HwndSource.FromHwnd(handle)?.AddHook(Hook);if(!RegisterHotKey(handle,1,0x4000|0x0002|0x0004,0x20))Notify("Ctrl+Shift+Space is in use. Open Rewind from the tray.");SetWindowDisplayAffinity(handle,0x11);FitDisplay();};
        Closing+=(_,e)=>{if(!quitting){e.Cancel=true;HideRewind();}};
        Closed+=(_,_)=>{UnregisterHotKey(new WindowInteropHelper(this).Handle,1);tray.Dispose();capture.Dispose();LocalInference.Stop();Store.Dispose();};
        Microsoft.Win32.SystemEvents.SessionSwitch+=(_,e)=>{if(e.Reason==Microsoft.Win32.SessionSwitchReason.SessionLock)Dispatcher.BeginInvoke(async()=>{if(capture.IsRecording)await ToggleRecording();});};
        PrepareDesktopBackdrop();Loaded+=(_,_)=>AnimateIn(this);ready=true;if(demoMode){DemoData.Install(Store);demo=true;SearchBox.Text="tps reports";}Reload();
    }
    private IntPtr Hook(IntPtr h,int msg,IntPtr w,IntPtr l,ref bool handled){if(msg==0x312){if(IsVisible&&IsActive)HideRewind();else ShowRewind();handled=true;}return IntPtr.Zero;}
    private void ShowRewind(){visibilityGeneration++;var appearing=!IsVisible;if(appearing)PrepareDesktopBackdrop();Show();FitDisplay();Activate();SearchBox.Focus();if(appearing)AnimateIn(this);}
    [DllImport("gdi32.dll")]private static extern bool DeleteObject(IntPtr handle);
    [DllImport("user32.dll")]private static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
    private void FitDisplay(){var b=System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position).Bounds;SetWindowPos(new WindowInteropHelper(this).Handle,new IntPtr(-1),b.X,b.Y,b.Width,b.Height,0x0040);}
    private void PrepareDesktopBackdrop(){
        // A transient in-memory backdrop, never persisted, indexed, or sent to a model.
        var bounds=System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position).Bounds;
        using var bitmap=new System.Drawing.Bitmap(bounds.Width,bounds.Height);
        using(var graphics=System.Drawing.Graphics.FromImage(bitmap))graphics.CopyFromScreen(bounds.Location,System.Drawing.Point.Empty,bounds.Size);
        var handle=bitmap.GetHbitmap();try{var source=Imaging.CreateBitmapSourceFromHBitmap(handle,IntPtr.Zero,Int32Rect.Empty,BitmapSizeOptions.FromEmptyOptions());source.Freeze();DesktopBackdrop.Source=source;}finally{DeleteObject(handle);}
    }
    private static void AnimateIn(UIElement view){if(!SystemParameters.ClientAreaAnimation)return;view.BeginAnimation(OpacityProperty,new System.Windows.Media.Animation.DoubleAnimation(0,1,TimeSpan.FromMilliseconds(220)){EasingFunction=new System.Windows.Media.Animation.CubicEase{EasingMode=System.Windows.Media.Animation.EasingMode.EaseOut}});}

    private void HideRewind(){
        if(!SystemParameters.ClientAreaAnimation){Hide();return;}
        var generation=++visibilityGeneration;var animation=new System.Windows.Media.Animation.DoubleAnimation(Opacity,0,TimeSpan.FromMilliseconds(160));animation.Completed+=(_,_)=>{if(generation!=visibilityGeneration)return;Hide();BeginAnimation(OpacityProperty,null);};BeginAnimation(OpacityProperty,animation);
    }
    private static Brush BrushOf(string hex)=>new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
    internal static Brush AppColor(string app)=>BrushOf(app switch{"Chrome"=>"#EC9B34","Messages"=>"#52CE62","Word"=>"#366CBC","Slack"=>"#632276","Keynote"=>"#399FED",_=>"#2385EF"});
    internal static BitmapImage LoadImage(string path,int decodeWidth=0)
    {
        var image=new BitmapImage();image.BeginInit();image.CacheOption=BitmapCacheOption.OnLoad;
        if(decodeWidth>0)image.DecodePixelWidth=decodeWidth;
        if(Path.GetExtension(path) is ".recallframe" or ".recallvideo")
        {
            var root=Directory.GetParent(Path.GetDirectoryName(path)!)!.FullName;
            using var stream=new MemoryStream(ImageArchive.Display(root,Path.GetRelativePath(root,path).Replace('\\','/'),decodeWidth));
            image.StreamSource=stream;image.EndInit();
        }
        else {image.UriSource=new Uri(Path.GetFullPath(path));image.EndInit();}
        image.Freeze();return image;
    }
    private void Reload(){if(!ready)return;try{
        frames=Store.Frames(SearchBox.Text,appFilter,starred,trash,demo,since);timeline=Store.Frames(trash:trash,demo:demo,since:since,limit:2000).OrderBy(x=>x.Timestamp).ToList();
        if(selected!=null&&!timeline.Any(f=>f.Id==selected.Id))LoadTimeline(selected.Timestamp);
        Cards.ItemsSource=frames.Select(f=>new{Frame=f,Image=LoadImage(Path.Combine(Store.Root,f.MeetingImagePath??f.ImagePath),360),BadgeColor=AppColor(f.AppName),Initial=f.AppName[..1]}).ToList();
        if(selected==null&&AskPanel.Visibility!=Visibility.Visible){SearchView.Visibility=timeline.Count==0&&string.IsNullOrEmpty(SearchBox.Text)?Visibility.Collapsed:Visibility.Visible;Welcome.Visibility=SearchView.Visibility==Visibility.Visible?Visibility.Collapsed:Visibility.Visible;}
        var home=timeline.Count>0&&SearchBox.Text.Length==0&&selected==null&&AskPanel.Visibility!=Visibility.Visible&&!trash&&!starred&&appFilter==null;
        HomeImage.Visibility=home?Visibility.Visible:Visibility.Collapsed;SearchBorder.RenderTransform=new TranslateTransform(0,home?245:0);SearchBorder.Background=BrushOf(home?"#E6FFFFFF":"#70FFFFFF");
        if(home){HomeImage.Source=LoadImage(Path.Combine(Store.Root,timeline[^1].ImagePath));SearchView.Visibility=Visibility.Collapsed;Welcome.Visibility=Visibility.Collapsed;}
        EmptyResults.Visibility=frames.Count==0?Visibility.Visible:Visibility.Collapsed;BuildFilters();BuildTimeline();
        StatusLabel.Text=demo?"DEMO · Sample memories":trash?"TRASH · Recoverable memories":capture.IsPrivacyPaused&&capture.IsRecording?"Recording paused · Excluded application is visible":capture.IsRecording?"● Recording on this device":"Everything stays on this device";
        RecordMenuItem.Header=capture.IsRecording?"Pause recording":"Start recording";tray.Text=capture.IsRecording?"Rewind Replica · Recording":"Rewind Replica · Paused";
    }catch(Exception ex){Notify(ex.Message);}}
    private void BuildFilters(){AppFilters.Children.Clear();void Add(string label,bool active,Action action){var b=new Button{Content=label,Background=BrushOf(active?"#BBFFFFFF":"#66FFFFFF"),MinWidth=105,Margin=new Thickness(0,0,12,0),Padding=new Thickness(13,9,13,9),FontSize=13};b.Click+=(_,_)=>action();AppFilters.Children.Add(b);}Add("★  Starred",starred,()=>{starred=!starred;Reload();});foreach(var app in Store.AppNames(demo,trash,since))Add(app,appFilter==app,()=>{appFilter=appFilter==app?null:app;Reload();});}
    private void BuildTimeline(){TimelineTracks.Children.Clear();var width=Math.Max(7,(Math.Max(980,ActualWidth)-78)/Math.Max(1,timeline.Count))*ZoomSlider.Value;foreach(var frame in timeline){var lines=new StackPanel{VerticalAlignment=VerticalAlignment.Center};lines.Children.Add(new System.Windows.Shapes.Rectangle{Height=frame.Starred?9:5,Fill=Brushes.White,Opacity=.4,Margin=new Thickness(0,0,0,3)});lines.Children.Add(new System.Windows.Shapes.Rectangle{Height=7,Fill=AppColor(frame.AppName)});var b=new Button{Content=lines,Width=width,Height=34,Padding=new Thickness(0),Margin=new Thickness(0,0,2,0),Background=selected?.Id==frame.Id?BrushOf("#77FFFFFF"):Brushes.Transparent,ToolTip=frame.TimeLabel+" · "+frame.AppName};b.Click+=(_,_)=>Select(frame);TimelineTracks.Children.Add(b);}FirstTime.Text=timeline.FirstOrDefault()?.Timestamp.LocalDateTime.ToString("h:mm tt")??"Your timeline starts here";LastTime.Text=timeline.LastOrDefault()?.Timestamp.LocalDateTime.ToString("h:mm tt")??"Now";}
    private void Select(MemoryFrame frame){if(!timeline.Any(f=>f.Id==frame.Id))LoadTimeline(frame.Timestamp);HomeImage.Visibility=Visibility.Collapsed;SearchBorder.RenderTransform=Transform.Identity;SearchBorder.Background=BrushOf("#70FFFFFF");selected=frame;meetingView=frame.MeetingImagePath!=null;VideoPlayer.Stop();VideoPlayer.Visibility=Visibility.Collapsed;ImageViewbox.Visibility=Visibility.Visible;Welcome.Visibility=SearchView.Visibility=AskPanel.Visibility=Visibility.Collapsed;Detail.Visibility=Visibility.Visible;AnimateIn(Detail);BackButton.Content="←";DateButton.Content=frame.Timestamp.LocalDateTime.ToString("MMM d h:mm tt");DetailTitle.Text=frame.AppName+" · "+frame.Title;transcript=frame.SessionId!=null?Store.Transcript(frame.SessionId):[];TranscriptSearch.Text=SearchBox.Text;RenderImage();RenderTranscript();BuildTimeline();}
    private void RenderImage(){if(selected==null)return;var path=meetingView?selected.MeetingImagePath??selected.ImagePath:selected.ImagePath;var image=LoadImage(Path.Combine(Store.Root,path));ImageCanvas.Width=image.PixelWidth;ImageCanvas.Height=image.PixelHeight;DetailImage.Source=image;DetailImage.Width=image.PixelWidth;DetailImage.Height=image.PixelHeight;
        while(ImageCanvas.Children.Count>1)ImageCanvas.Children.RemoveAt(1);
        foreach(var region in meetingView?selected.MeetingRegions:selected.Regions){var hit=new System.Windows.Shapes.Rectangle{Width=Math.Max(5,region.Width*image.PixelWidth),Height=Math.Max(5,region.Height*image.PixelHeight),Fill=!string.IsNullOrEmpty(SearchBox.Text)&&region.Text.Contains(SearchBox.Text,StringComparison.OrdinalIgnoreCase)?BrushOf("#77FFF25C"):Brushes.Transparent,Cursor=Cursors.IBeam,ToolTip=region.Text+" · Click to copy or open link"};Canvas.SetLeft(hit,region.X*image.PixelWidth);Canvas.SetTop(hit,region.Y*image.PixelHeight);hit.MouseLeftButtonDown+=(_,_)=>{var link=ModelClient.Links(region.Text).FirstOrDefault();if(link!=null)OpenUrl(link);else{Clipboard.SetText(region.Text);Notify("Copied to clipboard");}};var menu=new ContextMenu();var copy=new MenuItem{Header="Copy text"};copy.Click+=(_,_)=>Clipboard.SetText(region.Text);menu.Items.Add(copy);foreach(var link in ModelClient.Links(region.Text)){var open=new MenuItem{Header="Open "+link.Host};open.Click+=(_,_)=>OpenUrl(link);menu.Items.Add(open);}hit.ContextMenu=menu;ImageCanvas.Children.Add(hit);}
        PipButton.Visibility=selected.MeetingImagePath==null?Visibility.Collapsed:Visibility.Visible;if(selected.MeetingImagePath!=null)PipImage.Source=LoadImage(Path.Combine(Store.Root,meetingView?selected.ImagePath:selected.MeetingImagePath));
    }
    private void RenderTranscript(){TranscriptPanel.Children.Clear();TranscriptColumn.Width=new GridLength(transcript.Count==0?0:290);foreach(var line in transcript){var text=new TextBlock{TextWrapping=TextWrapping.Wrap,FontSize=12,LineHeight=17,Foreground=line.Speaker=="You"?Brushes.White:BrushOf("#2B293D")};var query=TranscriptSearch.Text;var index=!string.IsNullOrEmpty(query)?line.Text.IndexOf(query,StringComparison.OrdinalIgnoreCase):-1;if(index>=0){text.Inlines.Add(new Run(line.Text[..index]));text.Inlines.Add(new Run(line.Text.Substring(index,query.Length)){Background=Brushes.Yellow,Foreground=BrushOf("#2B293D")});text.Inlines.Add(new Run(line.Text[(index+query.Length)..]));}else text.Text=line.Text;var bubble=new Button{Content=text,Background=line.Speaker=="You"?BrushOf("#258BEE"):BrushOf("#66FFFFFF"),Padding=new Thickness(12,9,12,9),Margin=line.Speaker=="You"?new Thickness(24,0,0,10):new Thickness(0,0,15,10),HorizontalContentAlignment=HorizontalAlignment.Left,ToolTip=line.Timestamp.LocalDateTime.ToString("T")};bubble.Click+=(_,_)=>Jump(line.Timestamp);TranscriptPanel.Children.Add(bubble);}}
    private void Back(){if(selected!=null||AskPanel.Visibility==Visibility.Visible){selected=null;VideoPlayer.Stop();Detail.Visibility=AskPanel.Visibility=Visibility.Collapsed;SearchView.Visibility=Visibility.Visible;BackButton.Content="×";Reload();}else HideRewind();}
    private void LoadTimeline(DateTimeOffset date){timeline=Store.Frames(trash:trash,demo:demo,since:since,until:date,limit:1000).Concat(Store.Frames(trash:trash,demo:demo,since:date,limit:1000,ascending:true)).DistinctBy(f=>f.Id).OrderBy(f=>f.Timestamp).ToList();}
    private void Step(int delta){if(timeline.Count==0)return;var index=selected!=null?timeline.FindIndex(f=>f.Id==selected.Id):timeline.Count-1;var next=index+delta;if(next>=0&&next<timeline.Count){Select(timeline[next]);return;}var edge=delta<0?timeline[0]:timeline[^1];var frame=delta<0?Store.Frames(trash:trash,demo:demo,since:since,until:edge.Timestamp.AddMilliseconds(-1),limit:1).FirstOrDefault():Store.Frames(trash:trash,demo:demo,since:edge.Timestamp.AddMilliseconds(1),limit:1,ascending:true).FirstOrDefault();if(frame!=null)Select(frame);}
    private void Jump(DateTimeOffset date){var frame=Store.Frames(demo:demo,until:date,limit:1).FirstOrDefault()??Store.Frames(demo:demo,since:date,limit:1).FirstOrDefault();if(frame!=null){since=null;Reload();Select(frame);}else Notify("No recording at that time");}
    private async Task ToggleRecording(){if(transitioning)return;transitioning=true;try{if(capture.IsRecording){var session=await capture.Stop();Reload();if(session!=null)await Transcribe(session);}else{demo=false;trash=false;appFilter=null;SearchBox.Text="";selected=null;Detail.Visibility=AskPanel.Visibility=Visibility.Collapsed;await capture.Start(Settings);Reload();HideRewind();}}catch(Exception ex){MessageBox.Show(ex.Message,"Recording needs attention");}finally{transitioning=false;Reload();}}
    private async Task Transcribe(RecordingSession session){if(!Settings.TranscriptionEnabled||!session.HasAudio)return;StatusLabel.Text="Transcribing audio…";try{var tracks=new List<(string Path,double Offset,string Speaker)>();if(session.SystemAudioPath!=null)tracks.Add((session.SystemAudioPath,session.SystemAudioOffset,"Meeting"));if(session.MicrophoneAudioPath!=null)tracks.Add((session.MicrophoneAudioPath,session.MicrophoneAudioOffset,"You"));var lines=new List<TranscriptLine>();if(tracks.Count==0){var path=await Task.Run(()=>CaptureService.ExtractAudio(session,Store.Root));lines=await ModelClient.Transcribe(path,session,Settings.Speech,SecretStore.Read("speech"));}else foreach(var track in tracks){var source=Path.Combine(Store.Root,track.Path);var wave=source+".transcribe.wav";try{await Task.Run(()=>CaptureService.ConvertAudio(source,wave));var result=await ModelClient.Transcribe(wave,session with{StartedAt=session.StartedAt.AddSeconds(track.Offset)},Settings.Speech,SecretStore.Read("speech"));lines.AddRange(result.Select(line=>line with{Speaker=track.Speaker}));}finally{if(File.Exists(wave))File.Delete(wave);}}lines=lines.OrderBy(line=>line.Timestamp).ToList();Store.ReplaceTranscript(session.Id,lines);if(selected?.SessionId==session.Id){transcript=lines;RenderTranscript();}Reload();}catch(Exception ex){Notify("Audio is saved locally. Transcription failed: "+ex.Message);}}
    private void Notify(string text){ToastText.Text=text;Toast.Visibility=Visibility.Visible;toastTimer.Stop();toastTimer.Start();}
    internal async Task ApplySettings(AppSettings next,string chatKey,string speechKey){_ = ModelClient.Endpoint(next.Chat,"models");if(next.TranscriptionEnabled)_=ModelClient.Endpoint(next.Speech,"audio/transcriptions");var resume=capture.IsRecording;if(resume){var session=await capture.Stop();if(session!=null)await Transcribe(session);}SecretStore.Save("chat",chatKey);SecretStore.Save("speech",speechKey);Settings=next;File.WriteAllText(settingsFile,JsonSerializer.Serialize(Settings,new JsonSerializerOptions{WriteIndented=true}));
        using var key=Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run",true);if(next.LaunchAtLogin)key?.SetValue("RewindReplica",'"'+Environment.ProcessPath+'"');else key?.DeleteValue("RewindReplica",false);Store.Retain(next.RetentionDays);Reload();if(resume)await capture.Start(Settings);Notify("Settings saved");}
    private void OpenSettings(){ShowRewind();new SettingsWindow(this){Owner=this}.ShowDialog();}
    private async Task Quit(){try{var session=await capture.Stop();if(session!=null)await Transcribe(session);}catch(Exception ex){MessageBox.Show(ex.Message,"Recording finalization");}quitting=true;chatCancellation?.Cancel();Close();Application.Current.Shutdown();}
    private static void OpenUrl(Uri uri){if(uri.Scheme is "https" or "http")Process.Start(new ProcessStartInfo(uri.AbsoluteUri){UseShellExecute=true});}
    private async Task SendQuestion(){if(resettingChat)return;if(chatCancellation!=null){chatCancellation.Cancel();return;}var question=QuestionBox.Text.Trim();if(question.Length==0)return;QuestionBox.Clear();var history=messages.ToList();messages.Add(new("user",question));RenderChat();chatCancellation=new();SendButton.Content="■";
        try{var sources=Store.Retrieve(question,demo,since,appFilter);if(sources.Count==0){messages.Add(new("assistant","No memories are available in this range. Start recording or import an image first."));return;}var lines=sources.Select(f=>f.SessionId).Where(x=>x!=null).Distinct().SelectMany(x=>Store.Transcript(x!)).ToList();var displayedSources=Settings.Chat.IsBuiltin?sources.Take(5).ToList():sources;var index=messages.Count;messages.Add(new("assistant","",displayedSources));RenderChat();var lastRender=Stopwatch.StartNew();var answer=await ModelClient.Answer(question,displayedSources,lines,history,Settings.Chat,SecretStore.Read("chat"),chatCancellation.Token,partial=>{messages[index]=new("assistant",partial,displayedSources);if(lastRender.ElapsedMilliseconds>70){RenderChat();lastRender.Restart();}});messages[index]=new("assistant",answer,displayedSources);}catch(OperationCanceledException){}catch(Exception ex){Notify(ex.Message);messages.RemoveAll(m=>m.Role=="assistant"&&m.Text.Length==0);}finally{chatCancellation.Dispose();chatCancellation=null;SendButton.Content="↑";RenderChat();}}
    private async void NewChat_Click(object sender,RoutedEventArgs e){if(resettingChat)return;resettingChat=true;try{chatCancellation?.Cancel();while(chatCancellation!=null)await Task.Delay(50);messages.Clear();RenderChat();QuestionBox.Focus();}finally{resettingChat=false;}}
    private void RenderChat(){ChatMessages.Children.Clear();foreach(var message in messages){var stack=new StackPanel();stack.Children.Add(new TextBlock{Text=message.Role=="user"?"You":"Rewind",FontSize=11,FontWeight=FontWeights.Bold,Opacity=.6,Margin=new Thickness(0,0,0,10)});stack.Children.Add(new TextBox{Text=message.Text,IsReadOnly=true,TextWrapping=TextWrapping.Wrap,BorderThickness=new Thickness(0),Background=Brushes.Transparent,Padding=new Thickness(0),FontSize=14});if(message.Sources!=null){var links=new WrapPanel{Margin=new Thickness(0,12,0,0)};for(var i=0;i<message.Sources.Count;i++){var frame=message.Sources[i];var b=new Button{Content=$"[{i+1}] {frame.Title}",FontSize=11,MaxWidth=270,Margin=new Thickness(0,0,5,5)};b.Click+=(_,_)=>Select(frame);links.Children.Add(b);}stack.Children.Add(links);}ChatMessages.Children.Add(new Border{Child=stack,Padding=new Thickness(20),CornerRadius=new CornerRadius(15),Background=BrushOf(message.Role=="user"?"#33FFFFFF":"#66FFFFFF"),Margin=new Thickness(0,0,0,15)});}ChatScroll.ScrollToEnd();}
    private void Header_Drag(object s,MouseButtonEventArgs e){}
    private void Window_KeyDown(object s,System.Windows.Input.KeyEventArgs e){if(e.Key==Key.Escape){Back();e.Handled=true;}if(e.Key==Key.F&&Keyboard.Modifiers==ModifierKeys.Control){SearchBox.Focus();SearchBox.SelectAll();e.Handled=true;}if(Keyboard.FocusedElement is not TextBox){if(e.Key==Key.Left)Step(-1);if(e.Key==Key.Right)Step(1);}}
    private void Search_Changed(object s,TextChangedEventArgs e){if(SearchHint==null)return;SearchHint.Visibility=SearchBox.Text.Length==0?Visibility.Visible:Visibility.Collapsed;if(!ready)return;searchTimer.Stop();searchTimer.Start();}
    private void Search_KeyDown(object s,System.Windows.Input.KeyEventArgs e){if(e.Key==Key.Enter){selected=null;Detail.Visibility=AskPanel.Visibility=Visibility.Collapsed;Reload();}}
    private void ClearSearch_Click(object s,RoutedEventArgs e){SearchBox.Clear();selected=null;Detail.Visibility=AskPanel.Visibility=Visibility.Collapsed;Reload();}
    private void Back_Click(object s,RoutedEventArgs e)=>Back();
    private void Menu_Click(object s,RoutedEventArgs e){MainMenu.PlacementTarget=(Button)s;MainMenu.IsOpen=true;}
    private void Card_Click(object s,RoutedEventArgs e){if(((Button)s).Tag is MemoryFrame frame)Select(frame);}
    private async void Record_Click(object s,RoutedEventArgs e)=>await ToggleRecording();
    private void Settings_Click(object s,RoutedEventArgs e)=>OpenSettings();
    private void ModelSetup_Click(object s,RoutedEventArgs e)=>new SettingsWindow(this,true){Owner=this}.ShowDialog();
    private void Ask_Click(object s,RoutedEventArgs e){HomeImage.Visibility=Visibility.Collapsed;SearchBorder.RenderTransform=Transform.Identity;SearchBorder.Background=BrushOf("#70FFFFFF");selected=null;VideoPlayer.Stop();SearchView.Visibility=Welcome.Visibility=Detail.Visibility=Visibility.Collapsed;AskPanel.Visibility=Visibility.Visible;AnimateIn(AskPanel);BackButton.Content="←";ModelStatus.Text=Settings.Chat.IsLocal?$"Local model · {Settings.Chat.Model}":"Online model · Matching memory text is sent to the provider when you ask";QuestionBox.Focus();}
    private void Trash_Click(object s,RoutedEventArgs e){trash=!trash;selected=null;Detail.Visibility=AskPanel.Visibility=Visibility.Collapsed;Reload();}
    private void Demo_Click(object s,RoutedEventArgs e){if(demo){demo=false;SearchBox.Clear();}else{DemoData.Install(Store);demo=true;SearchBox.Text="tps reports";}trash=false;starred=false;appFilter=null;selected=null;Detail.Visibility=AskPanel.Visibility=Visibility.Collapsed;Reload();}
    private void Folder_Click(object s,RoutedEventArgs e)=>Process.Start(new ProcessStartInfo(Store.Root){UseShellExecute=true});
    
    private async void Quit_Click(object s,RoutedEventArgs e)=>await Quit();
    private void Pip_Click(object s,RoutedEventArgs e){meetingView=!meetingView;VideoPlayer.Stop();VideoPlayer.Visibility=Visibility.Collapsed;ImageViewbox.Visibility=Visibility.Visible;RenderImage();}
    private void Star_Click(object s,RoutedEventArgs e){if(selected==null)return;selected=selected with{Starred=!selected.Starred};Store.Save(selected);Reload();Notify(selected.Starred?"Memory starred":"Star removed");}
    private void Delete_Click(object s,RoutedEventArgs e){if(selected==null)return;if(trash)Store.Restore(selected);else Store.Trash(selected);Back();Notify(trash?"Memory restored":"Moved to Trash · Restore from the menu");}
    private void CopyText_Click(object s,RoutedEventArgs e){if(selected==null)return;var content=new TextBox{Text=selected.Text,IsReadOnly=true,TextWrapping=TextWrapping.Wrap,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,Margin=new Thickness(20)};new Window{Title="Recognized text · Select and copy",Content=content,Width=580,Height=500,Owner=this,WindowStartupLocation=WindowStartupLocation.CenterOwner}.Show();}
    private void Play_Click(object s,RoutedEventArgs e){if(selected?.SessionId==null)return;var session=Store.Session(selected.SessionId);if(session==null){Notify("This sample contains still frames only");return;}if(session.EndedAt==null){Notify("Pause recording to play the active segment");return;}VideoPlayer.Source=new Uri(Path.Combine(Store.Root,session.VideoPath));VideoPlayer.Visibility=Visibility.Visible;ImageViewbox.Visibility=Visibility.Collapsed;VideoPlayer.Play();}
    private void Video_Opened(object s,RoutedEventArgs e){if(selected?.SessionId!=null&&Store.Session(selected.SessionId) is {} session)VideoPlayer.Position=selected.Timestamp-session.StartedAt;}
    private void TranscriptSearch_Changed(object s,TextChangedEventArgs e){if(ready)RenderTranscript();}
    private void Timeline_Wheel(object s,MouseWheelEventArgs e){Step(e.Delta>0?-1:1);e.Handled=true;}
    private void Zoom_Changed(object s,RoutedPropertyChangedEventArgs<double> e){if(ready)BuildTimeline();}
    private void Jump_Click(object s,RoutedEventArgs e){var date=new DatePicker{SelectedDate=DateTime.Today,Margin=new Thickness(0,10,0,10)};var time=new TextBox{Text=DateTime.Now.ToString("HH:mm"),Margin=new Thickness(0,0,0,14)};var button=new Button{Content="Rewind to this time"};var panel=new StackPanel{Margin=new Thickness(24)};panel.Children.Add(new TextBlock{Text="Choose a date and time",FontSize=19});panel.Children.Add(date);panel.Children.Add(time);panel.Children.Add(button);var dialog=new Window{Title="Jump to date",Content=panel,Width=350,Height=260,Owner=this,WindowStartupLocation=WindowStartupLocation.CenterOwner,ResizeMode=ResizeMode.NoResize};button.Click+=(_,_)=>{if(date.SelectedDate is {} d&&TimeSpan.TryParse(time.Text,out var t)){Jump(new DateTimeOffset(d.Date+t));dialog.Close();}};dialog.ShowDialog();}
    private async void Import_Click(object s,RoutedEventArgs e){var dialog=new Microsoft.Win32.OpenFileDialog{Filter="Images|*.png;*.jpg;*.jpeg;*.bmp;*.tif;*.tiff",Multiselect=true};if(dialog.ShowDialog(this)!=true)return;try{foreach(var file in dialog.FileNames){var relative=$"frames/{Guid.NewGuid()}{Path.GetExtension(file)}";var target=Path.Combine(Store.Root,relative);File.Copy(file,target);var result=await capture.Recognize(target);Store.Save(new MemoryFrame{AppName="Imported",Title=Path.GetFileNameWithoutExtension(file),ImagePath=relative,Text=result.Text,Regions=result.Regions});}demo=false;SearchBox.Clear();appFilter=null;Reload();Notify("Images indexed locally");}catch(Exception ex){Notify(ex.Message);}}
    private void Export_Click(object s,RoutedEventArgs e){var dialog=new Microsoft.Win32.OpenFolderDialog{Title="Choose export destination"};if(dialog.ShowDialog(this)!=true)return;try{var destination=Path.Combine(dialog.FolderName,"Rewind Export "+DateTime.Now.ToString("yyyyMMdd-HHmmss"));Store.Export(destination,Store.Frames(SearchBox.Text,appFilter,starred,trash,demo,since,limit:10000));Process.Start(new ProcessStartInfo(destination){UseShellExecute=true});}catch(Exception ex){Notify(ex.Message);}}
    private async void Send_Click(object s,RoutedEventArgs e)=>await SendQuestion();
    private void LoadMore_Click(object s,RoutedEventArgs e){var more=Store.Frames(SearchBox.Text,appFilter,starred,trash,demo,since,offset:frames.Count);frames.AddRange(more);Cards.ItemsSource=frames.Select(f=>new{Frame=f,Image=LoadImage(Path.Combine(Store.Root,f.MeetingImagePath??f.ImagePath),360),BadgeColor=AppColor(f.AppName),Initial=f.AppName[..1]}).ToList();Notify(more.Count==0?"All matching memories are loaded":$"Loaded {more.Count} more memories");}
    private async void RetryTranscript_Click(object s,RoutedEventArgs e){if(!Settings.TranscriptionEnabled){Notify("Enable transcription in Settings first");return;}if(selected?.SessionId!=null&&Store.Session(selected.SessionId) is {} session&&session.EndedAt!=null)await Transcribe(session);else Notify("Select a finished recording first");}
    private async void Question_KeyDown(object s,System.Windows.Input.KeyEventArgs e){if(e.Key==Key.Enter)await SendQuestion();}
}
