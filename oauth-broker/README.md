# OpenSonos OAuth Broker

This Cloudflare Worker keeps the Sonos `client_secret` server-side and exposes a tiny public broker for the macOS app.

## Endpoints

- `GET /api/sonos/health`
- `GET /api/sonos/authorize?state=<opaque-state>`
- `POST /api/sonos/exchange`
- `POST /api/sonos/refresh`

## Required secrets

- `SONOS_CLIENT_ID`
- `SONOS_CLIENT_SECRET`
- `SONOS_REDIRECT_URI`

Recommended redirect URI:

- `https://open-sonos.kinan.fr/sonos-oauth-callback.html`

## Local development

1. Copy `.dev.vars.example` to `.dev.vars`
2. Rotate your Sonos secret and put the new one in `.dev.vars`
3. Run:

```bash
npx wrangler dev
```

## Deploy

```bash
cd oauth-broker
npx wrangler secret put SONOS_CLIENT_SECRET
npx wrangler deploy
```

Wrangler prints the final `https://<worker-name>.<your-workers-subdomain>.workers.dev` URL after deploy. Use that URL in the OpenSonos app.
