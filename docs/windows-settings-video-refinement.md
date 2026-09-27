# Windows settings and video refinement

Reference: the macOS `SettingsView.swift` and `DetailView.swift`, plus the native
video-page screenshot supplied on 2026-09-27. Settings retains Windows native
inputs inside grouped sections, with the five-category glass navigation above.

## Playback handoff

`VideoSurface` keeps decoded frames unpublished until media metadata is known
and the still-image orientation match has settled. It renders the final angle
and aspect into the XAML image source before raising `Ready`. `DetailView`
retains the original image until that signal, then switches the visible media
once. A late seek completion cannot bypass the match just because many decoder
callbacks occurred. Weak matches retain the existing bounded metadata fallback.

The detail page fits media to its actual aspect ratio, keeps application identity
and actions below it, and reserves a transcript column only when recognition is
complete and the filtered transcript contains nonempty text. Playback teardown
detaches its surface and restores the poster before another playback is prepared.

## Targeted validation

Run `scripts/test-windows-settings-video.ps1 -Directory <isolated-validation-root>`
against a development visual-parity instance with generated fixtures. It checks
the five Settings tabs, dark Settings, incomplete/complete/empty transcript
states, and startup with both zero and nonzero seek positions. The startup probes
capture a burst of screenshots and the readiness/poster/orientation state for
each capture. The fixture has physically rotated pixels with identity metadata,
so merely trusting MP4 rotation metadata cannot pass it.

The accompanying delivery evidence also measures the displayed colored video
corners. These are targeted checks, not a full regression run or a GPU frame-time
benchmark. The normal installed library is not used by this harness.
