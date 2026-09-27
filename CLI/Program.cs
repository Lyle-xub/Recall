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
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cancellation.Cancel(); };
Environment.ExitCode = await CliApplication.Run(args, Console.Out, Console.Error, cancellation.Token);
