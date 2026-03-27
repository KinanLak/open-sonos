const jsonHeaders = {
  "content-type": "application/json; charset=utf-8",
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET,POST,OPTIONS",
  "access-control-allow-headers": "content-type",
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: jsonHeaders })
    }

    const url = new URL(request.url)

    try {
      if (request.method === "GET" && url.pathname === "/") {
        return json({
          service: "open-sonos-oauth-broker",
          status: "ok",
          authorize: "/api/sonos/authorize?state=<opaque-state>",
          exchange: "POST /api/sonos/exchange",
          refresh: "POST /api/sonos/refresh",
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
