# HTTP Client And Server (`genex/http`)

This document describes the current `genex/http` extension surface. It is an
implementation reference, not a language-spec document.

Core implementation lives in `src/genex/http.nim`.

## Import And Globals

Typical usage:

```gene
(import genex/http)
```

The extension registers:

- global helpers: `http_get`, `http_post`, `start_server`, `respond`,
  `respond_sse`, `redirect`, `ws_connect`
- classes in the `gene` namespace: `gene/Request`, `gene/Response`,
  `gene/ServerRequest`, `gene/ServerStream`, `gene/WsConnection`

## Client API

### `http_get` and `http_post`

```gene
(var response (await (http_get "https://example.com")))
(println response/status)
(println response/body)

(var post_response (await (http_post "https://example.com/api" "{^ok true}")))
```

These helpers return a completed `Future` whose value is a `gene/Response`.
Internally the current implementation performs the request synchronously and
wraps the result in a completed future.

### `gene/Request`

```gene
(var req (new gene/Request "https://example.com" "GET"))
(var response (await (req .send)))
```

Constructor shape:

```gene
(new gene/Request url [method] [headers] [body])
```

Stored fields:

- `url`
- `method`
- `headers`
- `body`

### `gene/Response`

```gene
(var resp (new gene/Response 200 "{\"ok\":true}"))
(println resp/status)
(println ((resp .json)/ok))
```

Constructor shape:

```gene
(new gene/Response status body [headers])
```

Current surface:

- fields: `status`, `body`, `headers`
- method: `.json`

## Server API

### `start_server`

```gene
(fn app [req]
  (if (req/path == "/")
    (respond 200 "hello")
  else
    (respond 404 "not found")))

(start_server 8086 app)
(run_forever)
```

Current keywords:

- `^concurrent true|false`
- `^workers <int>`
- `^queue_limit <positive-int>`: actor-backed concurrent-mode mailbox capacity per HTTP request worker. Defaults to `10000`; values above `10000`, zero, negative values, and non-integers fail at server start.
- `^max_in_flight <positive-int>`: optional cap for accepted actor-backed HTTP requests currently awaiting a worker reply. Omit it for the historical unlimited behavior; configured values must be `1..10000`.
- `^overload_status <int>`: HTTP status returned for deterministic backpressure responses. Defaults to `503` and must be in the `400..599` range.
- `^request_timeout_ms <positive-int>`: actor-backed concurrent-mode deadline while waiting for a worker reply. Defaults to `10000` (10 seconds); values must be `1..600000` and non-integers fail at server start.
- `^websocket {^path "/ws" ^handler handler}`

Current ownership model:

- `^concurrent true` routes request execution through actor-backed request
  ports instead of the older extension-local Gene thread pool.
- Concurrent dispatch uses a non-blocking actor-port enqueue. If all request
  workers are saturated, or if `^max_in_flight` has been reached, the server
  returns the configured overload status immediately instead of waiting on actor
  mailbox space.
- The default overload response is status `503` with the small body
  `Service overloaded`. The body is intentionally fixed and does not include
  request bodies, tokens, or headers.
- Stopped or invalid actor request ports fail closed with a safe `500` response;
  detailed low-overhead counters/status are added by the later readiness
  diagnostics work.
- Actor-backed request timeouts are cooperative abandonment boundaries. When a
  worker reply is not available within `^request_timeout_ms`, the HTTP request
  is completed with status `504` and body `Async response error: await timed out`,
  the reply future is failed with the same `GENE.ASYNC.TIMEOUT` shape used by
  `await ^timeout`, and runtime tracking is detached so a later stale actor
  reply is ignored. The actor turn may still finish later; Gene does not
  preempt or cancel the running actor handler.
- Timeout diagnostics currently stay in low-overhead internal counters used by
  readiness tests (`request_timeout_ms`, timeout count, last timeout error, and
  timestamp) and the existing `http_log` path. They intentionally omit request
  bodies, tokens, and full headers.
- SSE and websocket upgrade handling stay on the live server-owner lane because
  they still require the live socket/client object.

The current example is [examples/http_server.gene](../examples/http_server.gene).

Actor-backed example:

```gene
(import genex/http)

(gene/actor/enable ^workers 4)

(var worker
  (gene/actor/spawn
    ^state 0
    (fn [ctx msg state]
      (case msg/kind
      when "job"
        (do
          (println #"actor #{state} started job #{msg/job_id}")
          (sleep 250)
          (+ state 1))
      else
        state))))

(fn app [req]
  (if (req/path == "/enqueue")
    (do
      (worker .send {^kind "job" ^job_id 1})
      (respond 202 "queued"))
  else
    (respond 200 "ok")))

(start_server 8087 app)
(run_forever)
```

See [examples/http_actor_server.gene](../examples/http_actor_server.gene) for a slightly fuller sample with a small actor pool and a `/stats` endpoint.

### `gene/ServerRequest`

Handlers receive a `gene/ServerRequest`. Current methods:

- `.path`
- `.method`
- `.url`
- `.params`
- `.headers`
- `.body`
- `.body_params`

Example:

```gene
(fn app [req]
  (respond 200 (req/path)))
```

### `respond`

`respond` constructs a `ServerResponse` value.

Supported call shapes:

```gene
(respond "ok")
(respond 404)
(respond 200 "ok")
(respond 200 "ok" {^Content-Type "text/plain"})
```

### `respond_sse`

```gene
(fn sse_handler [req]
  (var stream (respond_sse req))
  (stream .send "data: hello\n\n")
  (stream .close))
```

Returns a `gene/ServerStream` with:

- `.send`
- `.close`

### `redirect`

```gene
(redirect "https://example.com")
(redirect "https://example.com/login" 302)
```

Returns a `ServerResponse` with a `Location` header.

### WebSocket Hooks

The extension also exposes:

- `ws_connect`
- `gene/WsConnection`

Server-side websocket support is wired through the `^websocket` option on
`start_server`. The code is present in `src/genex/http.nim`, but the docs and
examples around websocket usage are still thin.

## Current Limitations

- The HTTP extension is not yet described in `spec/`.
- Client helpers currently wrap blocking requests in completed futures instead
  of performing true async network I/O.
- WebSocket support exists in the extension, but it needs better examples and
  focused tests.
- Dynamic extension loading of `genex/http` now uses host-side JSON helper
  wrappers for `json_parse` / `json_stringify` to avoid depending on the older
  top-level string return path from the dylib.
