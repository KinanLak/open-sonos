# OpenSonos

OpenSonos is a macOS menubar app that discovers Sonos speakers on the local network and can also connect to the Sonos cloud control API for account-backed households.

The Sonos OAuth `client_secret` is no longer stored in the app. Cloud auth now goes through a tiny OAuth broker service in `oauth-broker/`.

## MVP

- menubar-only app (`LSUIElement`)
- local Sonos discovery over SSDP
- group detection via `ZoneGroupTopology`
- now playing title and playback state
- play/pause, previous, next
- group volume slider and mute toggle
- optional Sonos cloud OAuth support
- multi-household switching for cloud-backed systems, including separate S1/S2 households when Sonos exposes them separately
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

## Sonos Cloud setup

1. Create a Sonos `Direct Control` integration in the Sonos developer portal.
2. Deploy `docs/sonos-oauth-callback.html` at `https://open-sonos.kinan.fr/sonos-oauth-callback.html`.
3. Register that exact HTTPS URL as the Sonos redirect URL.
4. Deploy the broker in `oauth-broker/` and configure:
   - `SONOS_CLIENT_ID`
   - `SONOS_CLIENT_SECRET`
   - `SONOS_REDIRECT_URI=https://open-sonos.kinan.fr/sonos-oauth-callback.html`
5. Deploy the Worker and copy the generated `workers.dev` URL.
6. In OpenSonos, open `Sonos Cloud` and set the broker URL to that `workers.dev` address, for example `https://open-sonos-oauth-broker.kinan-lakh.workers.dev`.
7. Click `Connect` and complete the browser login.

The callback page forwards the Sonos authorization code to `opensonos://oauth-callback`, and the app exchanges the code through the broker instead of holding the Sonos secret locally.

## Architecture

- `open-sonos/Sources/SonosModel.swift`: domain models
- `open-sonos/Sources/SonosSOAPClient.swift`: transport layer
- `open-sonos/Sources/SonosDiscoveryClient.swift`: local discovery and Sonos state loading
- `open-sonos/Sources/SonosCloudClient.swift`: Sonos cloud OAuth and Control API calls
- `open-sonos/Sources/SonosCloudModel.swift`: cloud models and defensive decoding
- `open-sonos/Sources/SonosKeychainStore.swift`: local secret and token storage
- `open-sonos/Sources/SonosControlClient.swift`: playback and volume commands
- `open-sonos/Sources/SonosStore.swift`: observable app state and refresh policy
- `open-sonos/Sources/*View.swift`: render-only menu bar UI
- `oauth-broker/`: server-side Sonos OAuth exchange/refresh broker

## Known limits

- Sonos cloud still requires a deployed broker plus your Sonos developer integration
- the `workers.dev` hostname is account-specific, so the broker URL must be copied once after deploy
- no widgets, shortcuts, AppleScript, guest-mode polish, or event subscriptions yet
- no event subscriptions yet; refresh uses polling
