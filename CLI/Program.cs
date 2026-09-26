using Recall.Cli;
using Rewind;

using var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cancellation.Cancel(); };
Environment.ExitCode = await CliApplication.Run(args, Console.Out, Console.Error, cancellation.Token);
