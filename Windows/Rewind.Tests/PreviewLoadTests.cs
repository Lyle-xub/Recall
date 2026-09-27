using Recall;

internal static class PreviewLoadTests
{
    readonly record struct Snapshot(string Pixels, string Header);

    public static async Task Run(Action<bool, string> assert)
    {
        var requests = new LatestPreviewLoad<Snapshot>();
        var displayed = new Snapshot("old pixels", "old time");
        var first = new TaskCompletionSource<Snapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        var second = new TaskCompletionSource<Snapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        var loadingFirst = requests.Request(_ => first.Task, value => displayed = value);
        var loadingSecond = requests.Request(_ => second.Task, value => displayed = value);
        assert(displayed == new Snapshot("old pixels", "old time"), "Preview keeps pixels and metadata paired while another image decodes");
        first.SetResult(new("obsolete pixels", "obsolete time"));
        await loadingFirst;
        assert(displayed == new Snapshot("old pixels", "old time"), "A canceled decode cannot replace either current pixels or metadata");
        second.SetResult(new("latest pixels", "latest time"));
        await loadingSecond;
        assert(displayed == new Snapshot("latest pixels", "latest time"), "The newest completed decode switches image and header together");

        var canceled = new TaskCompletionSource<Snapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        var loadingCanceled = requests.Request(_ => canceled.Task, value => displayed = value);
        requests.Cancel();
        canceled.SetResult(new("hidden pixels", "hidden time"));
        await loadingCanceled;
        assert(displayed == new Snapshot("latest pixels", "latest time"), "Unloading a preview rejects an in-flight image");

        var staleFailure = new TaskCompletionSource<Snapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        var currentFailure = new TaskCompletionSource<Snapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        var failureCount = 0;
        var old = requests.Request(_ => staleFailure.Task, _ => { }, _ => failureCount++);
        var current = requests.Request(_ => currentFailure.Task, _ => { }, _ => failureCount++);
        staleFailure.SetException(new IOException("obsolete failure"));
        await old;
        assert(failureCount == 0, "An obsolete decode failure cannot cover the current preview");
        currentFailure.SetException(new IOException("current failure"));
        await current;
        assert(failureCount == 1 && displayed == new Snapshot("latest pixels", "latest time"),
            "A current failure reports an error without replacing the last valid image or header");
    }
}
