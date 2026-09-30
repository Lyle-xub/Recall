namespace Rewind;

/// One serial recognizer; a durable backlog changes idle time, never pixel coverage.
public static class OcrWorkPolicy
{
    public const int Window = 32;
    public static TimeSpan Recovery(TimeSpan work, int pending) =>
        TimeSpan.FromSeconds(Math.Clamp(work.TotalSeconds * (pending >= Window ? .05 : .25), .15, pending >= Window ? .5 : 2));
}
