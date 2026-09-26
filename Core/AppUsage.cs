namespace Rewind;

public record AppIdentity(string Name, string Process, string? ExecutablePath = null, string Kind = "application");
public record AppInterval(string Id, AppIdentity App, DateTimeOffset Start, DateTimeOffset End)
{
    public double Seconds => Math.Max(0, (End - Start).TotalSeconds);
}
public sealed class UsageRecorder
{
    private readonly MemoryStore store;
    public AppInterval? Current
    {
        get; private set;
    }
    public UsageRecorder(MemoryStore store)
    {
        this.store = store;
    }
    public void Transition(AppIdentity identity, DateTimeOffset date)
    {
        var boundary = Current != null && Current.End > date ? Current.End : date;
        if (Current?.App == identity)
        {
            Checkpoint(boundary);
            return;
        }
        Checkpoint(boundary);
        Current = new(Guid.NewGuid().ToString(), identity, boundary, boundary);
        store.SaveUsage(Current);
    }
    public void Checkpoint(DateTimeOffset date)
    {
        if (Current == null)
            return;
        Current = Current with
        {
            End = date > Current.End ? date : Current.End
        };
        store.SaveUsage(Current);
    }
    public void Stop(DateTimeOffset date)
    {
        Checkpoint(date);
        Current = null;
    }
}
public record UsageApp(AppIdentity App, double Seconds);
public record UsageReport(DateTime Date, double TotalSeconds, List<UsageApp> Apps, double[] Hours, double[] Week)
{
    public static UsageReport Build(DateTime day, IEnumerable<AppInterval> source, TimeZoneInfo? zone = null)
    {
        zone ??= TimeZoneInfo.Local;
        day = day.Date;
        var items = source.Where(x => x.App.Kind == "application").ToList();
        DateTimeOffset Boundary(DateTime t) => new(TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(t, DateTimeKind.Unspecified), zone));
        var begin = Boundary(day);
        var end = Boundary(day.AddDays(1));
        double Overlap(AppInterval i, DateTimeOffset a, DateTimeOffset b) => Math.Max(0, ((i.End < b ? i.End : b) - (i.Start > a ? i.Start : a)).TotalSeconds);
        var apps = items.GroupBy(x => x.App.Process).Select(g => new UsageApp(g.First().App, g.Sum(x => Overlap(x, begin, end)))).Where(x => x.Seconds > 0).OrderByDescending(x => x.Seconds).ToList();
        var hours = new double[24];
        // Walk actual elapsed hours so a DST overlap is attributed without double-counting.
        for (var tick = begin; tick < end; tick = tick.AddHours(1))
        {
            var next = tick.AddHours(1);
            if (next > end)
                next = end;
            hours[TimeZoneInfo.ConvertTime(tick, zone).Hour] += items.Sum(x => Overlap(x, tick, next));
        }
        var first = day.AddDays(-(int)day.DayOfWeek);
        var week = Enumerable.Range(0, 7).Select(d => items.Sum(x => Overlap(x, Boundary(first.AddDays(d)), Boundary(first.AddDays(d + 1))))).ToArray();
        return new(day, apps.Sum(x => x.Seconds), apps, hours, week);
    }
}
public static class TimelineMath
{
    public static readonly double[] Presets = [60, 300, 900, 3600, 21600, 86400];
    public static double Clamp(double seconds) => double.IsFinite(seconds) ? Math.Clamp(seconds, 60, 86400) : 300;
    public static string Duration(double seconds) => seconds < 60 ? $"{Math.Max(0, (int)seconds)} sec" : seconds < 3600 ? $"{seconds / 60:0.#} min" : $"{seconds / 3600:0.#} hr";
    public static List<AppInterval> Continuous(IEnumerable<AppInterval> source, DateTimeOffset start, DateTimeOffset end)
    {
        var result = new List<AppInterval>();
        var cursor = start;
        foreach (var raw in source.OrderBy(x => x.Start))
        {
            var a = raw.Start > start ? raw.Start : start;
            var b = raw.End < end ? raw.End : end;
            if (b <= cursor || a >= end)
                continue;
            if (a > cursor)
                result.Add(new("gap-" + cursor.Ticks, new("No activity", "", Kind: "unavailable"), cursor, a));
            if (a < cursor)
                a = cursor;
            result.Add(raw with
            {
                Start = a,
                End = b
            });
            cursor = b;
        }
        if (cursor < end)
            result.Add(new("gap-" + cursor.Ticks, new("No activity", "", Kind: "unavailable"), cursor, end));
        return result;
    }
}
