using Recall.Cli;
using Rewind;

if(args.Length==2 && args[0]=="--internal-service")
{
    Console.SetOut(TextWriter.Null);Console.SetError(TextWriter.Null);
    using var stop=new CancellationTokenSource();
    using var terminate=OperatingSystem.IsWindows()?null:System.Runtime.InteropServices.PosixSignalRegistration.Create(System.Runtime.InteropServices.PosixSignal.SIGTERM,context=>{context.Cancel=true;stop.Cancel();});
    Console.CancelKeyPress+=(_,e)=>{e.Cancel=true;stop.Cancel();};
    await HeadlessService.Serve(Path.GetFullPath(args[1]),stop.Token);return;
}
using var cancellation = new CancellationTokenSource();
// Console.CancelKeyPress initializes the POSIX terminal (and writes mode
// escapes) even when stdout must be pure JSON. Native signal registration
// preserves cancellation without configuring terminal input/output modes.
using var interrupt = OperatingSystem.IsWindows() ? null : System.Runtime.InteropServices.PosixSignalRegistration.Create(System.Runtime.InteropServices.PosixSignal.SIGINT, context => { context.Cancel = true; cancellation.Cancel(); });
if (OperatingSystem.IsWindows()) Console.CancelKeyPress += (_, e) => { e.Cancel = true; cancellation.Cancel(); };
var terminal = TerminalEnvironment.Detect(Console.Out, Console.Error, measureWidth: !args.Contains("--json"));
using var streams = new TerminalStreams();
Environment.ExitCode = await CliApplication.Run(args, streams.Output, streams.Error, cancellation.Token, terminal);
