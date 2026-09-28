# Windows UI refactor validation — 2026-09-28

This pass rebuilds the Windows Rhine presentation against the checked-in macOS visual reference. Validation ran inside the local Parallels `Windows 11` VM at 2748×1624 physical pixels, 200% scaling, and 1374×812 logical pixels.

## Result

- The full-window backdrop now uses a calmer neutral field with stronger blur and theme-specific desktop contribution.
- Search, close, menu, and action controls sample the desktop backdrop while Rhine is active, preventing card content from producing hard stripes inside the controls.
- Card rims and shadows are softer, and distant cards receive image, glass, and neutral depth haze based on camera distance.
- The wall decodes 192 px previews and realizes only a short decorative tail around real records. This reduces decode pressure and removes the dense wireframe appearance.
- Floating date/count labels make the five-day layout legible. Expanded cards use the same visual proportion and bottom timeline reservation as the macOS reference.
- Reduced-motion realization can fill up to eight visible sheets per UI turn so large seeks settle without leaving placeholders on screen.

Windows Composition and DWM provide the material on Windows; Apple’s private material implementation is not available. The refactor matches the reference’s hierarchy, contrast, translucency, depth, and motion while keeping a Windows-native rendering path.

## Visual comparison rounds

The source references are in `docs/macos-visual-reference/app-baseline/`. Captures from the VM are in the ignored `.test-data/windows-parity/` directory:

1. `baseline-*`: initial Windows state.
2. `round1-*`: full 17-state pass after backdrop, control material, labels, and depth changes.
3. `round2-*`: targeted Rhine light/dark home and expanded tuning.
4. `candidate-*`: final Rhine light/dark home and expanded captures after card sizing and placeholder-tail fixes.

The final four captures are:

- `.test-data/windows-parity/candidate-rhine-light-home/000.png`
- `.test-data/windows-parity/candidate-rhine-light-expanded/000.png`
- `.test-data/windows-parity/candidate-rhine-dark-home/000.png`
- `.test-data/windows-parity/candidate-rhine-dark-expanded/000.png`

## Real Windows validation

- Core, database, retrieval, privacy, and model contracts: **328 passed**.
- Archive benchmark: 20,431 rows, 210.7 ms median, 325.7 ms maximum in the final release build.
- Rhine transition suite: normal open/close, interrupted return, reduced motion, wave settling, and idle checks passed. Idle CPU was 3.71% of one core.
- Control motion suite: search open/close, eight retargets, card open/close, reduced motion, and idle checks passed. Idle CPU was 3.43% of one core.
- Glass suite: material, background, fallback, forced host failure, recovery, and classic presentation passed in light and dark themes (12 states).

The VM initially lacked the x64 Visual C++ runtime required by `CustomEffectRuntimeNative.dll`. Installing Microsoft’s x64 redistributable enabled the foreground shader path; the glass suite then reported `EffectsAvailable=true` with no material error.

The final self-contained x64 portable package contains all required OCR, LLM,
Whisper, tessdata, application, and material assets. Its SHA-256 is
`5b9a6c820ea2c842ba3de050070a6d019758c177aec622c5694e41f9083f8776`.
