import { DurableObject } from "cloudflare:workers"

const jsonHeaders = {
  "content-type": "application/json; charset=utf-8",
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET,POST,OPTIONS",
  "access-control-allow-headers": "content-type",
}

const SONOS_API_BASE = "https://api.ws.sonos.com/control/api/v1"

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: jsonHeaders })
    }

    const url = new URL(request.url)

    try {
      // Real-time relay: the app opens a WebSocket; a per-household Durable Object
      // subscribes to Sonos events and forwards incoming webhooks to the app.
      if (url.pathname === "/api/sonos/relay") {
        return relayWebSocket(request, env, url)
      }

      // Sonos posts events to this single, pre-registered callback URL.
      if (request.method === "POST" && url.pathname === "/api/sonos/webhook") {
        return relayWebhook(request, env)
      }

      if (request.method === "GET" && url.pathname === "/") {
        return json({
          service: "open-sonos-oauth-broker",
          status: "ok",
          authorize: "/api/sonos/authorize?state=<opaque-state>",
          exchange: "POST /api/sonos/exchange",
          refresh: "POST /api/sonos/refresh",
          config: "/api/sonos/config",
          relay: "GET /api/sonos/relay?householdId=<id> (WebSocket)",
          webhook: "POST /api/sonos/webhook (Sonos event callback)",
        })
      }

      if (request.method === "GET" && url.pathname === "/api/sonos/config") {
        assertConfiguration(env)
        return json({
          clientId: env.SONOS_CLIENT_ID,
          redirectUri: env.SONOS_REDIRECT_URI,
          webhookUrl: new URL("/api/sonos/webhook", url.origin).toString(),
        })
      }

      if (request.method === "GET" && url.pathname === "/api/sonos/health") {
        assertConfiguration(env)
        return json({
          status: "ok",
          redirectUri: env.SONOS_REDIRECT_URI,
          clientIdSuffix: env.SONOS_CLIENT_ID.slice(-6),
        })
      }

      if (request.method === "GET" && url.pathname === "/api/sonos/authorize") {
        assertConfiguration(env)

        const state = url.searchParams.get("state") || crypto.randomUUID()
        const authorizationURL = new URL("https://api.sonos.com/login/v3/oauth")
        authorizationURL.searchParams.set("client_id", env.SONOS_CLIENT_ID)
        authorizationURL.searchParams.set("response_type", "code")
        authorizationURL.searchParams.set("state", state)
        authorizationURL.searchParams.set("scope", "playback-control-all")
        authorizationURL.searchParams.set("redirect_uri", env.SONOS_REDIRECT_URI)

        return Response.redirect(authorizationURL.toString(), 302)
      }

      if (request.method === "POST" && url.pathname === "/api/sonos/exchange") {
        assertConfiguration(env)
        const payload = await readJSON(request)
        const code = stringValue(payload.code)

        if (!code) {
          return json({ error: "missing_code" }, { status: 400 })
        }

        return tokenResponse(
          await exchangeToken(env, {
            grant_type: "authorization_code",
            code,
            redirect_uri: env.SONOS_REDIRECT_URI,
          })
        )
      }

      if (request.method === "POST" && url.pathname === "/api/sonos/refresh") {
        assertConfiguration(env)
        const payload = await readJSON(request)
        const refreshToken = stringValue(payload.refresh_token)

        if (!refreshToken) {
          return json({ error: "missing_refresh_token" }, { status: 400 })
        }

        return tokenResponse(
          await exchangeToken(env, {
            grant_type: "refresh_token",
            refresh_token: refreshToken,
          })
        )
      }

      return json({ error: "not_found" }, { status: 404 })
    } catch (error) {
      return handleError(error)
    }
  },
}

async function exchangeToken(env, formFields) {
  const requestBody = new URLSearchParams()

  for (const [key, value] of Object.entries(formFields)) {
    if (value) {
      requestBody.set(key, value)
    }
  }

  const credentials = btoa(`${env.SONOS_CLIENT_ID}:${env.SONOS_CLIENT_SECRET}`)
  const response = await fetch("https://api.sonos.com/login/v3/oauth/access", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded;charset=utf-8",
      authorization: `Basic ${credentials}`,
    },
    body: requestBody.toString(),
  })

  const text = await response.text()
  let body

  try {
    body = JSON.parse(text)
  } catch {
    body = { raw: text }
  }

  if (!response.ok) {
    throw new HTTPError(response.status, {
      error: "sonos_oauth_failed",
      details: body,
    })
  }

  return body
}

function tokenResponse(payload) {
  return json({
    access_token: payload.access_token,
    refresh_token: payload.refresh_token,
    expires_in: payload.expires_in,
    scope: payload.scope,
  })
}

function assertConfiguration(env) {
  if (!stringValue(env.SONOS_CLIENT_ID) || !stringValue(env.SONOS_CLIENT_SECRET) || !isHTTPSURL(env.SONOS_REDIRECT_URI)) {
    throw new HTTPError(500, {
      error: "broker_not_configured",
      message: "Set SONOS_CLIENT_ID, SONOS_CLIENT_SECRET, and SONOS_REDIRECT_URI.",
    })
  }
}

async function readJSON(request) {
  try {
    return await request.json()
  } catch {
    throw new HTTPError(400, { error: "invalid_json" })
  }
}

function stringValue(value) {
  if (typeof value !== "string") {
    return ""
  }

  return value.trim()
}

function isHTTPSURL(value) {
  try {
    const url = new URL(value)
    return url.protocol === "https:"
  } catch {
    return false
  }
}

function json(body, init = {}) {
  return new Response(JSON.stringify(body, null, 2), {
    ...init,
    headers: {
      ...jsonHeaders,
      ...(init.headers || {}),
    },
  })
}

function handleError(error) {
  if (error instanceof HTTPError) {
    return json(error.body, { status: error.status })
  }

  return json(
    {
      error: "internal_error",
      message: error instanceof Error ? error.message : "Unknown error",
    },
    { status: 500 }
  )
}

class HTTPError extends Error {
  constructor(status, body) {
    super(body?.message || body?.error || `HTTP ${status}`)
    this.status = status
    this.body = body
  }
}

// MARK: - Real-time relay

function relayWebSocket(request, env, url) {
  if (request.headers.get("Upgrade") !== "websocket") {
    return json({ error: "expected_websocket" }, { status: 426 })
  }

  const householdId = stringValue(url.searchParams.get("householdId") || "")
  if (!householdId) {
    return json({ error: "missing_household_id" }, { status: 400 })
  }

  const stub = env.RELAY.get(env.RELAY.idFromName(householdId))
  return stub.fetch(new Request("https://relay/ws", request))
}

async function relayWebhook(request, env) {
  const householdId = request.headers.get("X-Sonos-Household-Id")
  if (!householdId) {
    return new Response("ignored", { status: 200 })
  }

  // Verify authenticity unless explicitly disabled for bring-up debugging.
  if (env.RELAY_SKIP_SIGNATURE !== "1") {
    const valid = await verifyEventSignature(request, env)
    if (!valid) {
      return new Response("invalid_signature", { status: 403 })
    }
  }

  const stub = env.RELAY.get(env.RELAY.idFromName(householdId))
  return stub.fetch(new Request("https://relay/webhook", request))
}

async function verifyEventSignature(request, env) {
  const provided = request.headers.get("X-Sonos-Event-Signature")
  if (!provided) return false

  const concatenation = [
    request.headers.get("X-Sonos-Event-Seq-Id") || "",
    request.headers.get("X-Sonos-Namespace") || "",
    request.headers.get("X-Sonos-Type") || "",
    request.headers.get("X-Sonos-Target-Type") || "",
    request.headers.get("X-Sonos-Target-Value") || "",
    env.SONOS_CLIENT_ID,
    env.SONOS_CLIENT_SECRET,
  ].join("")

  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(concatenation))
  const expected = base64UrlNoPad(digest)
  return expected === provided
}

function base64UrlNoPad(buffer) {
  const bytes = new Uint8Array(buffer)
  let binary = ""
  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

/// One instance per Sonos household. Holds the app's WebSocket(s), subscribes to
/// Sonos events on the app's behalf, and forwards incoming webhooks to the app.
export class SonosRelay extends DurableObject {
  async fetch(request) {
    const url = new URL(request.url)

    if (url.pathname === "/ws") {
      const firstClient = this.ctx.getWebSockets().length === 0
      const pair = new WebSocketPair()
      const [client, server] = Object.values(pair)
      this.ctx.acceptWebSocket(server)
      // Start each session from a clean slate so the first configure re-subscribes
      // from scratch (robust if a prior session's cleanup didn't run).
      if (firstClient) {
        await this.ctx.storage.delete("subscribed")
      }
      return new Response(null, { status: 101, webSocket: client })
    }

    if (url.pathname === "/webhook") {
      return this.handleWebhook(request)
    }

    return new Response("not_found", { status: 404 })
  }

  async webSocketMessage(ws, raw) {
    let message
    try {
      message = JSON.parse(typeof raw === "string" ? raw : new TextDecoder().decode(raw))
    } catch {
      return
    }

    switch (message.type) {
      case "configure":
        await this.configure(message)
        break
      case "token":
        if (stringValue(message.accessToken)) {
          const config = (await this.ctx.storage.get("config")) || {}
          config.accessToken = message.accessToken
          await this.ctx.storage.put("config", config)
        }
        break
      case "ping":
        try { ws.send(JSON.stringify({ type: "pong" })) } catch {}
        break
      default:
        break
    }
  }

  async webSocketClose() {
    // When the last app disconnects, stop renewing and release subscriptions.
    if (this.ctx.getWebSockets().length <= 1) {
      await this.unsubscribeAll()
      await this.ctx.storage.deleteAlarm()
      await this.ctx.storage.delete("config")
      await this.ctx.storage.delete("subscribed")
    }
  }

  async alarm() {
    if (this.ctx.getWebSockets().length === 0) return
    const config = await this.ctx.storage.get("config")
    if (!config) return
    await this.subscribeAll(config, { force: true })
    await this.ctx.storage.setAlarm(Date.now() + 6 * 60 * 60 * 1000)
  }

  // MARK: - Configuration & subscriptions

  async configure(message) {
    const householdId = stringValue(message.householdId)
    const accessToken = stringValue(message.accessToken)
    const groupIds = Array.isArray(message.groupIds) ? message.groupIds.filter((id) => stringValue(id)) : []
    if (!householdId || !accessToken) return

    const config = { householdId, accessToken, groupIds }
    await this.ctx.storage.put("config", config)
    await this.subscribeAll(config)
    await this.ctx.storage.setAlarm(Date.now() + 6 * 60 * 60 * 1000)
  }

  // Only subscribe to *new* targets and unsubscribe *removed* ones. Re-POSTing an
  // existing subscription makes Sonos re-send current state, which (via the app's
  // groups-changed handler) would reconfigure and loop. `force` re-POSTs everything
  // for periodic renewal from the alarm, where no reconfigure loop can occur.
  async subscribeAll(config, { force = false } = {}) {
    const desired = this.desiredSubscriptions(config)
    const previous = (await this.ctx.storage.get("subscribed")) || []

    const toRemove = previous.filter((path) => !desired.includes(path))
    const toAdd = force ? desired : desired.filter((path) => !previous.includes(path))

    for (const path of toRemove) {
      await this.callSonos("DELETE", path, config.accessToken)
    }
    for (const path of toAdd) {
      await this.callSonos("POST", path, config.accessToken)
    }

    await this.ctx.storage.put("subscribed", desired)
  }

  async unsubscribeAll() {
    const config = await this.ctx.storage.get("config")
    const previous = (await this.ctx.storage.get("subscribed")) || []
    if (config?.accessToken) {
      for (const path of previous) {
        await this.callSonos("DELETE", path, config.accessToken)
      }
    }
    await this.ctx.storage.delete("subscribed")
  }

  desiredSubscriptions(config) {
    const paths = [`/households/${config.householdId}/groups/subscription`]
    for (const groupId of config.groupIds) {
      paths.push(`/groups/${groupId}/playback/subscription`)
      paths.push(`/groups/${groupId}/playbackMetadata/subscription`)
      paths.push(`/groups/${groupId}/groupVolume/subscription`)
    }
    return paths
  }

  async callSonos(method, path, accessToken) {
    try {
      return await fetch(`${SONOS_API_BASE}${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
      })
    } catch {
      return null
    }
  }

  // MARK: - Event forwarding

  async handleWebhook(request) {
    const body = await request.text()
    const payload = JSON.stringify({
      type: "event",
      namespace: request.headers.get("X-Sonos-Namespace") || "",
      eventType: request.headers.get("X-Sonos-Type") || "",
      targetType: request.headers.get("X-Sonos-Target-Type") || "",
      targetValue: request.headers.get("X-Sonos-Target-Value") || "",
      householdId: request.headers.get("X-Sonos-Household-Id") || "",
      body,
    })

    for (const ws of this.ctx.getWebSockets()) {
      try { ws.send(payload) } catch {}
    }

    return new Response("ok", { status: 200 })
  }
}
