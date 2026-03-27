# OpenSonos

OpenSonos is a macOS menubar app that discovers Sonos speakers on the local network and exposes the core controls directly from the menu bar.

## MVP

- menubar-only app (`LSUIElement`)
- local Sonos discovery over SSDP
- group detection via `ZoneGroupTopology`
- now playing title and playback state
- play/pause, previous, next
- group volume slider and mute toggle
- automatic refresh loop
- Tuist-first build and launch workflow

## Run locally

```bash
./run-menubar.sh
```

Stop the app explicitly:

```bash
./stop-menubar.sh
```

## Build manually

```bash
TUIST_SKIP_UPDATE_CHECK=1 tuist generate --no-open
TUIST_SKIP_UPDATE_CHECK=1 tuist xcodebuild build -scheme OpenSonos -configuration Debug -derivedDataPath .derivedData
```

## Tests

```bash
TUIST_SKIP_UPDATE_CHECK=1 tuist xcodebuild test -scheme OpenSonos -configuration Debug -derivedDataPath .derivedData
```

## Architecture

- `open-sonos/Sources/SonosModel.swift`: domain models
- `open-sonos/Sources/SonosSOAPClient.swift`: transport layer
- `open-sonos/Sources/SonosDiscoveryClient.swift`: local discovery and Sonos state loading
- `open-sonos/Sources/SonosControlClient.swift`: playback and volume commands
- `open-sonos/Sources/SonosStore.swift`: observable app state and refresh policy
- `open-sonos/Sources/*View.swift`: render-only menu bar UI

## Known MVP limits

- local-network MVP only, no Sonos cloud OAuth yet
- no widgets, shortcuts, AppleScript, guest-mode polish, or S1/S2 switching UI yet
- no event subscriptions yet; refresh uses polling
