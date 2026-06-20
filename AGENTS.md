# AGENTS

Guidance for AI agents working in this repo. See `README.md` for the user-facing overview and architecture.

## Build & run

Compile and launch the app with the project script — **not** a bare `xcodebuild`:

```bash
./run-menubar.sh      # generate (Tuist) + build + relaunch the menubar app
./stop-menubar.sh     # stop the running app
```

`run-menubar.sh` runs `tuist generate` then builds into `./.derivedData` and `open`s the app.

Manual build / tests (same toolchain as the script):

```bash
TUIST_SKIP_UPDATE_CHECK=1 tuist xcodebuild build -scheme OpenSonos -configuration Debug -derivedDataPath .derivedData
TUIST_SKIP_UPDATE_CHECK=1 tuist xcodebuild test  -scheme OpenSonos -configuration Debug -derivedDataPath .derivedData
```

This is a Tuist project: `Project.swift` is the source of truth. The `.xcodeproj` / `.xcworkspace` are generated — don't hand-edit them.

## Verifying changes

- **Single-file SourceKit diagnostics are noise.** Editing a `*View.swift` often reports `Cannot find type 'SonosStore'` etc. — those types live in sibling files in the same module and only resolve in a full build. Trust the build, not the per-file diagnostics.
- A compile is clean only after a real build. To surface compile warnings reliably, remove build intermediates first (`rm -rf .derivedData/Build/Intermediates.noindex/OpenSonos.build`) so unchanged files get recompiled.
- SwiftUI **runtime** warnings (e.g. *"Picker: the selection is invalid and does not have an associated tag"*) won't show in the build log — they appear when the view renders. A `Picker` whose selection can be absent should use an **optional** selection (`String?`, tags wrapped with `Optional(...)`) so "nothing selected" is a valid, warning-free state.

## Spotify Connect

- Transfer uses Spotify Desktop's bundled `spotify_cli` helper (no API token / Client ID). Lookup order is in `SpotifyDesktopClient.spotifyCLIURL()`.
- Inspect real device payloads with:
  ```bash
  ./Spotify.app/Contents/MacOS/spotify_cli devices list --format json
  ```
  The same physical device can appear twice — e.g. `device_type: "tv"` (native Spotify app) and `device_type: "cast_video"` (Google Cast). The menu disambiguates duplicate names as `Name • Spotify App` vs `Name • Cast`.

## Conventions

- `*View.swift` files are render-only; app state and refresh policy live in `SonosStore.swift`.
- Prefer native macOS affordances (e.g. inline `Picker` checkmarks over manually greyed/disabled rows).
