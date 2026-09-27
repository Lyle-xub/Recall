using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using Rewind;
namespace Recall.Cli;

public sealed record TerminalEnvironment(bool OutputTty, bool ErrorTty, int Width, Func<string,string?> Variable, bool PowerShell = false)
{
    public static TerminalEnvironment Detect(TextWriter output,TextWriter error,bool measureWidth=true)
    {
        bool outputTty=ReferenceEquals(output,Console.Out)&&!Console.IsOutputRedirected;
        bool errorTty=ReferenceEquals(error,Console.Error)&&!Console.IsErrorRedirected;
        int width=80;
        // Console.WindowWidth initializes .NET's terminal input mode and can
        // write ESC sequences even for JSON/NO_COLOR. Read capabilities only.
        if(measureWidth)
        {
            if(int.TryParse(Environment.GetEnvironmentVariable("COLUMNS"),out var columns)&&columns>0)width=columns;
            else if((outputTty||errorTty)&&!OperatingSystem.IsWindows()&&GetWindowSize((IntPtr)(outputTty?1:2),out var size)==0&&size.Columns>0)width=size.Columns;
            else if((outputTty||errorTty)&&OperatingSystem.IsWindows()&&GetConsoleScreenBufferInfo(GetStdHandle(outputTty?-11:-12),out var info))width=info.Right-info.Left+1;
        }
        return new(outputTty,errorTty,width,Environment.GetEnvironmentVariable,OperatingSystem.IsWindows());
    }
    [StructLayout(LayoutKind.Sequential)] struct WindowSize {public ushort Rows,Columns,Width,Height;}
    [StructLayout(LayoutKind.Sequential)] struct BufferInfo {public short SizeX,SizeY,CursorX,CursorY;public ushort Attributes;public short Left,Top,Right,Bottom,MaximumX,MaximumY;}
    // Use the .NET runtime's fixed-arity wrapper: direct variadic ioctl has
    // a different calling convention on Apple ARM64. No terminal setup occurs.
    [DllImport("System.Native",EntryPoint="SystemNative_GetWindowSize",SetLastError=true)] static extern int GetWindowSize(IntPtr fd,out WindowSize size);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll")] [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetConsoleScreenBufferInfo(IntPtr handle,out BufferInfo info);
}
public sealed class TerminalStyle
{
    public bool Color {get;}
    public bool Icons {get;}
    public bool Ascii {get;}
    public string Ellipsis=>Ascii?"...":"…";
    public string Separator=>Ascii?" | ":" · ";
    public bool Chinese {get;}
    public bool PowerShell {get;}
    public int Width {get;}
    public TerminalStyle(Arguments? args,TerminalEnvironment environment,bool error=false)
    {
        var mode=args?.Get("color")??"auto";
        if(mode is not ("auto" or "always" or "never"))throw new RecallException("usage","--color must be auto, always or never.");
        var language=args?.Get("lang");
        if(language!=null && language is not ("zh" or "en"))throw new RecallException("usage","--lang must be zh or en (OCR uses --language).");
        var locale=language??new[]{environment.Variable("LC_ALL"),environment.Variable("LC_MESSAGES"),environment.Variable("LANG"),CultureInfo.CurrentUICulture.Name}.FirstOrDefault(s=>!string.IsNullOrEmpty(s))??"en";
        Chinese=locale.StartsWith("zh",StringComparison.OrdinalIgnoreCase);PowerShell=environment.PowerShell;
        var tty=error?environment.ErrorTty:environment.OutputTty;
        Color=args?.Has("json")!=true && (mode=="always" || mode=="auto" && tty && environment.Variable("NO_COLOR")==null && environment.Variable("TERM")!="dumb");
        Icons=args?.Has("json")!=true && args?.Has("ascii")!=true && tty && environment.Variable("TERM")!="dumb";
        Ascii=args?.Has("ascii")==true || !tty || environment.Variable("TERM")=="dumb";
        Width=Math.Clamp(environment.Width,20,240);
    }
    public string T(string en,string zh)=>Chinese?zh:en;
    public string Paint(string text,string code)=>Color?$"\u001b[{code}m{text}\u001b[0m":text;
    public string Heading(string text,string icon="▸")=>Paint((Icons?icon+" ":"== ")+text,"36");
    public string Success(string text)=>Paint((Icons?"✓ ":"[OK] ")+text,"32");
    public string Warning(string text)=>Paint((Icons?"⚠ ":"[!] ")+text,"33");
    public string Failure(string text)=>Paint((Icons?"✗ ":"[ERROR] ")+text,"31");
    public string Dim(string text)=>Paint(text,"2");
}
public static class TerminalText
{
    public static string Clean(string? value,bool multiline=false)
    {
        if(string.IsNullOrEmpty(value))return "";
        var clean=new StringBuilder();var text=value.Replace("\r\n","\n");
        for(int i=0;i<text.Length;i++)
        {
            var c=text[i];
            if(c=='\u001b' || c is '\u009b' or '\u009d' or '\u0090' or '\u009e' or '\u009f')
            {
                var kind=c=='\u001b'?(++i<text.Length?text[i]:'\0'):c switch {'\u009b'=>'[','\u009d'=>']',_=>'P'};
                if(kind=='[') {while(++i<text.Length && text[i] is not (>= '@' and <= '~')) {} }
                else if(kind is ']' or 'P' or '^' or '_') {while(++i<text.Length) {if(text[i] is '\a' or '\u009c')break;if(text[i]=='\u001b' && i+1<text.Length && text[i+1]=='\\'){i++;break;}}}
                continue;
            }
            if(c is '\n' or '\r' or '\t') {clean.Append(multiline && c!='\t'?'\n':' ');continue;}
            if(char.IsControl(c) || c is >= '\u202a' and <= '\u202e' or >= '\u2066' and <= '\u2069' or '\u200e' or '\u200f' or '\ufeff')continue;
            clean.Append(c);
        }
        // Rune decoding replaces malformed UTF-16 without splitting valid pairs.
        return string.Concat(clean.ToString().EnumerateRunes().Select(r=>r.ToString()));
    }
    public static IEnumerable<string> Elements(string text)
    {var e=StringInfo.GetTextElementEnumerator(text);while(e.MoveNext())yield return e.GetTextElement();}
    static int CellWidth(string element)
    {
        int width=0;bool emoji=element.Contains('\ufe0f') || element.Contains('\u20e3');
        foreach(var rune in element.EnumerateRunes())
        {
            var code=rune.Value;var category=Rune.GetUnicodeCategory(rune);
            if(category is UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark or UnicodeCategory.Format)continue;
            bool wide=code is >=0x1100 and <=0x115f or >=0x2329 and <=0x232a or >=0x2e80 and <=0xa4cf or >=0xac00 and <=0xd7a3 or >=0xf900 and <=0xfaff or >=0xfe10 and <=0xfe19 or >=0xfe30 and <=0xfe6f or >=0xff00 and <=0xff60 or >=0xffe0 and <=0xffe6 or >=0x1f000 and <=0x1faff or >=0x20000 and <=0x3fffd;
            width=Math.Max(width,wide?2:1);
        }
        return emoji?Math.Max(width,2):width;
    }
    public static int Width(string text)=>Elements(text).Sum(CellWidth);
    public static string Clip(string text,int width,string ellipsis="…")
    {
        if(Width(text)<=width)return text;
        var result=new StringBuilder();int used=0,budget=Math.Max(0,width-Width(ellipsis));
        foreach(var element in Elements(text)){var cells=CellWidth(element);if(used+cells>budget)break;result.Append(element);used+=cells;}
        return result+(width>=Width(ellipsis)?ellipsis:"");
    }
    public static IEnumerable<string> Wrap(string text,int width)
    {
        foreach(var line in text.Split('\n'))
        {
            var result=new StringBuilder();int used=0;
            foreach(var element in Elements(line))
            {
                var cells=CellWidth(element);
                if(used+cells>width && used>0)
                {
                    var current=result.ToString();int split=current.LastIndexOf(' ');
                    if(split>0 && Width(current[..split])>=width/2)
                    {yield return current[..split];result.Clear().Append(current[(split+1)..]);used=Width(result.ToString());}
                    else {yield return current;result.Clear();used=0;}
                }
                result.Append(element);used+=cells;
            }
            yield return result.ToString();
        }
    }
    public static string Quote(string value,bool powerShell=false)
    {
        if(value.Length>0 && value.All(c=>char.IsAsciiLetterOrDigit(c)||"-._/:=@".Contains(c)))return value;
        return "'"+value.Replace("'",powerShell?"''":"'\"'\"'")+"'";
    }
    public static string Command(IEnumerable<string> words,bool powerShell=false)=>string.Join(' ',words.Select(w=>Quote(w,powerShell)));
}

/// UnixConsoleStream configures the terminal on its first write in some .NET
/// runtimes. CLI output uses plain descriptors so JSON/NO_COLOR are byte-stable.
public sealed class TerminalStreams:IDisposable
{
    public TextWriter Output {get;}
    public TextWriter Error {get;}
    readonly bool ownsWriters;
    public TerminalStreams()
    {
        ownsWriters=!OperatingSystem.IsWindows();
        Output=ownsWriters?Writer(1):Console.Out;Error=ownsWriters?Writer(2):Console.Error;
    }
    static TextWriter Writer(int descriptor)=>new StreamWriter(new FileStream(new Microsoft.Win32.SafeHandles.SafeFileHandle((IntPtr)descriptor,ownsHandle:false),FileAccess.Write),new UTF8Encoding(false)){AutoFlush=true};
    public void Dispose(){if(ownsWriters){Output.Dispose();Error.Dispose();}}
}
