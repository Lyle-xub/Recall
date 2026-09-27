# Windows usage navigation crash investigation

Two pre-fix validation runs crashed while returning from **App usage** to the Rhine home page after a longer sequence of navigation, dismissals, and performance probes. The crash dumps were recorded from isolated validation processes 264 (18:49:15) and 17900 (18:55:42) on 27 September 2026. A fresh, shorter navigation sequence had passed, so the failure depended on the longer lifecycle sequence.

Both dumps report native exception `0xC000027B` (stowed exception) on the UI thread. Their first stowed HRESULT is `0x8000FFFF` (`E_UNEXPECTED`); the first dump also contains four `0x80004005` (`E_FAIL`) records. `dotnet-dump` found no managed exception. With the SDK command-line debugger, both UI stacks reach the same `Microsoft_UI_Xaml+0x3AD79D` fail-fast site. Lower in each reentrant stack are `uiautomationcore!UiaDisconnectProvider+0x24F` and WinUI frames. These are evidence of a failure during XAML/UI Automation provider teardown; they do not identify a unique application-level cause. The WER minidumps omit the memory referenced by the stowed native backtraces, so those backtraces could not be recovered.

`UsageView.Load` previously could complete after navigation had removed the view, then call `Render` on the detached XAML tree. The lifecycle fix cancels its pending load on `Unloaded`, advances the revision, detaches the parent size handler, and checks cancellation, revision, and attachment before rendering. This addresses a plausible teardown race without changing Rhine or toolbar behavior.

After that fix, the isolated reproduction passed the complete `nav1 → dismiss → performance → nav2` sequence. An additional `nav3 → performance` pressure pass also completed without a crash. The final UI and video regressions passed. These A/B results support the Usage lifecycle fix, but the native dumps alone cannot prove it was the sole cause.

Raw debugger logs remain outside the package at `D:/RecallDevelopment/tools/recall-crash264-fast.log` and `D:/RecallDevelopment/tools/recall-crash17900-fast.log`. Crash dumps are diagnostic artifacts and are not included in the release.
