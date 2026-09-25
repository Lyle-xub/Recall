using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Button=System.Windows.Controls.Button;
using TextBox=System.Windows.Controls.TextBox;
using ComboBox=System.Windows.Controls.ComboBox;
using CheckBox=System.Windows.Controls.CheckBox;
using Orientation=System.Windows.Controls.Orientation;
namespace Rewind;
public sealed class SettingsWindow : Window {
    private readonly MainWindow owner;
    private readonly AppSettings draft;
    private readonly TextBlock status=new(){TextWrapping=TextWrapping.Wrap,FontSize=12,Foreground=Brushes.DimGray,MaxWidth=460};
    private readonly List<Action> collect=[];
    private readonly PasswordBox chatKey=new(),speechKey=new();
    public SettingsWindow(MainWindow owner,bool modelSetup=false) {
        this.owner=owner;draft=JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(owner.Settings))!;
        Title="Rewind settings";Width=710;Height=760;MinWidth=600;MinHeight=620;WindowStartupLocation=WindowStartupLocation.CenterOwner;Background=new SolidColorBrush(System.Windows.Media.Color.FromRgb(247,246,251));
        var root=new DockPanel{Margin=new Thickness(24)};Content=root;
        var header=new TextBlock{Text="Rewind settings",FontSize=25,FontWeight=FontWeights.SemiBold,Margin=new Thickness(0,0,0,20)};DockPanel.SetDock(header,Dock.Top);root.Children.Add(header);
        var footer=new DockPanel{Margin=new Thickness(0,20,0,0)};DockPanel.SetDock(footer,Dock.Bottom);root.Children.Add(footer);var save=new Button{Content="Save settings",Margin=new Thickness(12,0,0,0)};DockPanel.SetDock(save,Dock.Right);footer.Children.Add(save);footer.Children.Add(status);
        var tabs=new TabControl();root.Children.Add(tabs);
        var recording=Tab(tabs,"Recording");Note(recording,"Recordings start only when you press Start. Close the window to continue recording from the system tray.");
        Select(recording,"Capture interval",new[]{"2","3","5","10"},draft.CaptureInterval.ToString(),s=>draft.CaptureInterval=int.Parse(s));
        Select(recording,"Display",new[]{"Primary display"}.Concat(System.Windows.Forms.Screen.AllScreens.Select(s=>s.DeviceName)).ToArray(),draft.DisplayName??"Primary display",s=>draft.DisplayName=s=="Primary display"?null:s);
        Toggle(recording,"Record system audio",draft.SystemAudio,v=>draft.SystemAudio=v);Toggle(recording,"Record microphone",draft.Microphone,v=>draft.Microphone=v);
        Note(recording,"Screen and audio are encoded locally using Windows Media Foundation. Audio is transcribed after each 5-minute segment, or when you pause.");
        Toggle(recording,"Open at login (recording remains paused)",draft.LaunchAtLogin,v=>draft.LaunchAtLogin=v);
        Label(recording,"Excluded applications");Note(recording,"One process name per line, without .exe. Recording pauses while an excluded application's window is visible.");
        var exclusions=new TextBox{Text=string.Join("\n",draft.ExcludedApps),AcceptsReturn=true,Height=100,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};recording.Children.Add(exclusions);collect.Add(()=>draft.ExcludedApps=exclusions.Text.Split(['\r','\n'],StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries));
        var models=Tab(tabs,"Models");Profile(models,"Ask Rewind",draft.Chat,chatKey,false);
        chatKey.Password=SecretStore.Read("chat");speechKey.Password=SecretStore.Read("speech");
        var test=new Button{Content="Test connection & list models",HorizontalAlignment=HorizontalAlignment.Left,Margin=new Thickness(0,10,0,10)};models.Children.Add(test);
        test.Click+=async(_,_)=>{try{foreach(var action in collect)action();status.Text="Connecting…";var list=await ModelClient.Models(draft.Chat,chatKey.Password);status.Text="Connected · "+string.Join(", ",list.Take(10));}catch(Exception ex){status.Text=ex.Message;}};
        Note(models,"Local mode accepts localhost only. For an online provider, asking a question sends matching screen text and transcripts to that provider; it does not upload screenshots.");
        Toggle(models,"Transcribe recorded audio",draft.TranscriptionEnabled,v=>draft.TranscriptionEnabled=v);Profile(models,"Meeting transcription",draft.Speech,speechKey,true);
        Note(models,"Built-in Whisper runs automatically after you download it. With an online speech provider, recorded audio segments are uploaded while transcription is enabled.");
        var storage=Tab(tabs,"Storage");Label(storage,"Your data");Note(storage,owner.Store.Root);
        Select(storage,"Keep history",new[]{"7","30","90","Forever"},draft.RetentionDays==0?"Forever":draft.RetentionDays.ToString(),s=>draft.RetentionDays=s=="Forever"?0:int.Parse(s));
        Note(storage,"Older unstarred memories move to recoverable Trash. Starred memories are retained. API keys are encrypted with Windows DPAPI for the current user.");
        var empty=new Button{Content="Empty Trash permanently",HorizontalAlignment=HorizontalAlignment.Left};storage.Children.Add(empty);empty.Click+=(_,_)=>{if(System.Windows.MessageBox.Show(this,"Permanently delete all memories in Trash and recordings no retained memory uses? This cannot be undone.","Empty Trash",MessageBoxButton.YesNo,MessageBoxImage.Warning)!=MessageBoxResult.Yes)return;try{status.Text=$"Deleted {owner.Store.EmptyTrash()} memories and their unused recordings";}catch(Exception ex){status.Text=ex.Message;}};
        Label(storage,"Shortcuts");Note(storage,"Ctrl + Shift + Space — open / hide Rewind\nCtrl + F — focus search\n← / → — previous / next moment\nEsc — back / close");
        Note(storage,"Rewind Replica · Native Windows edition\nIndependent implementation of the interface and workflow shown in the reference video.");
        if(modelSetup)tabs.SelectedIndex=1;
        save.Click+=async(_,_)=>{save.IsEnabled=false;try{foreach(var action in collect)action();await owner.ApplySettings(draft,chatKey.Password,speechKey.Password);Close();}catch(Exception ex){status.Text=ex.Message;}finally{save.IsEnabled=true;}};
    }
    private static StackPanel Tab(TabControl tabs,string name){var stack=new StackPanel{Margin=new Thickness(20)};tabs.Items.Add(new TabItem{Header=name,Content=new ScrollViewer{Content=stack,VerticalScrollBarVisibility=ScrollBarVisibility.Auto}});return stack;}
    private static void Label(Panel panel,string text)=>panel.Children.Add(new TextBlock{Text=text,FontWeight=FontWeights.SemiBold,FontSize=15,Margin=new Thickness(0,17,0,8)});
    private static void Note(Panel panel,string text)=>panel.Children.Add(new TextBlock{Text=text,TextWrapping=TextWrapping.Wrap,FontSize=12,LineHeight=18,Foreground=Brushes.DimGray,Margin=new Thickness(0,5,0,10)});
    private void Toggle(Panel panel,string label,bool value,Action<bool> set){var check=new CheckBox{Content=label,IsChecked=value,Margin=new Thickness(0,10,0,7)};panel.Children.Add(check);collect.Add(()=>set(check.IsChecked==true));}
    private void Select(Panel panel,string label,string[] values,string initial,Action<string> set){Label(panel,label);var box=new ComboBox{ItemsSource=values,SelectedItem=initial,Padding=new Thickness(8)};panel.Children.Add(box);collect.Add(()=>set(box.SelectedItem?.ToString()??values[0]));}
    private void Profile(Panel panel,string label,ModelProfile profile,PasswordBox key,bool speech){
        Label(panel,label);var providers=speech?new[]{"Built-in","Local Whisper","Online compatible"}:new[]{"Built-in","Ollama","LM Studio","Online compatible"};
        var provider=new ComboBox{ItemsSource=providers,SelectedItem=profile.Provider,Padding=new Thickness(8),Margin=new Thickness(0,0,0,10)};
        var url=new TextBox{Text=profile.BaseUrl,Margin=new Thickness(0,0,0,10)};var model=new TextBox{Text=profile.Model,Margin=new Thickness(0,0,0,10)};
        panel.Children.Add(provider);
        var localPanel=new StackPanel();panel.Children.Add(localPanel);ModelCard(localPanel,speech?"speech":"chat");
        var advanced=new StackPanel();panel.Children.Add(advanced);Note(advanced,"API base URL");advanced.Children.Add(url);Note(advanced,"Model name");advanced.Children.Add(model);Note(advanced,"API key (optional for local)");key.Padding=new Thickness(10,7,10,7);advanced.Children.Add(key);
        void VisibilityForProvider(){var builtin=provider.SelectedItem?.ToString()=="Built-in";localPanel.Visibility=builtin?Visibility.Visible:Visibility.Collapsed;advanced.Visibility=builtin?Visibility.Collapsed:Visibility.Visible;}
        VisibilityForProvider();
        provider.SelectionChanged+=(_,_)=>{var p=provider.SelectedItem?.ToString()??providers[0];url.Text=p switch{"Built-in"=>"http://127.0.0.1/v1","Ollama"=>"http://127.0.0.1:11434/v1","LM Studio"=>"http://127.0.0.1:1234/v1","Local Whisper"=>"http://127.0.0.1:8080/v1",_=>"https://api.openai.com/v1"};model.Text=p=="Built-in"?(speech?"Whisper · Base":"Qwen3 · 1.7B"):p=="Ollama"?"qwen3:8b":speech?"whisper-1":"";VisibilityForProvider();};
        collect.Add(()=>{profile.Provider=provider.SelectedItem?.ToString()??providers[0];profile.IsLocal=profile.Provider!="Online compatible";profile.BaseUrl=url.Text.Trim();profile.Model=model.Text.Trim();});
    }
    private void ModelCard(Panel parent,string id){
        var library=BuiltinModels.Shared;var item=library.Catalog.FirstOrDefault(m=>m.Id==id);if(item==null){Note(parent,"Model catalog missing. Install the complete application package.");return;}
        var content=new StackPanel{Margin=new Thickness(18)};var card=new Border{Child=content,Background=Brushes.White,CornerRadius=new CornerRadius(16),BorderThickness=new Thickness(1),BorderBrush=new SolidColorBrush(System.Windows.Media.Color.FromRgb(230,229,239))};parent.Children.Add(card);
        var heading=new DockPanel();content.Children.Add(heading);var button=new Button{HorizontalAlignment=HorizontalAlignment.Right};DockPanel.SetDock(button,Dock.Right);heading.Children.Add(button);heading.Children.Add(new TextBlock{Text=item.Title,FontSize=18,FontWeight=FontWeights.SemiBold,VerticalAlignment=VerticalAlignment.Center});
        Note(content,item.Subtitle);Note(content,item.SizeLabel+" · "+item.License);var progress=new ProgressBar{Height=4,Maximum=1,Margin=new Thickness(0,6,0,10)};content.Children.Add(progress);var detail=new TextBlock{TextWrapping=TextWrapping.Wrap,FontSize=12,Foreground=Brushes.DimGray};content.Children.Add(detail);
        var license=new Button{Content="Model details & license",FontSize=11,Margin=new Thickness(0,10,0,0),HorizontalAlignment=HorizontalAlignment.Left};license.Click+=(_,_)=>System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(item.Source){UseShellExecute=true});content.Children.Add(license);
        void Refresh(){progress.Value=library.Progress.GetValueOrDefault(id);progress.Visibility=library.Busy(id)?Visibility.Visible:Visibility.Collapsed;detail.Text=library.Status.GetValueOrDefault(id,"Download once. Rewind runs the model automatically, even offline.");button.Content=library.Busy(id)?"Pause":library.Installed.Contains(id)?"Remove":"Download";}
        void Changed()=>Dispatcher.Invoke(Refresh);library.Changed+=Changed;Closed+=(_,_)=>library.Changed-=Changed;
        button.Click+=async(_,_)=>{try{if(library.Busy(id))library.Pause(id);else if(library.Installed.Contains(id))library.Remove(item);else await library.Download(item);}catch(Exception ex){detail.Text=ex.Message;}};Refresh();
    }
}
