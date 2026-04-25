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

- global helpers: `http_get`, `http_post`, `start_server`,
  `http_server_status`, `respond`, `respond_sse`, `redirect`,
  `ws_connect`
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
- `^workers <int>`: requested actor-backed HTTP request workers. Defaults to `4`; values must be positive integers. Requests above the supported cap (`8`) are clamped visibly and exposed as `requested_workers`, `effective_workers`, and `worker_clamped` in `http_server_status`.
- `^queue_limit <positive-int>`: actor-backed concurrent-mode mailbox capacity per HTTP request worker. Defaults to `10000`; values above `10000`, zero, negative values, and non-integers fail at server start.
- `^max_in_flight <positive-int>`: optional cap for accepted actor-backed HTTP requests currently awaiting a worker reply. Omit it for the historical unlimited behavior; configured values must be `1..10000`.
- `^overload_status <int>`: HTTP status returned for deterministic backpressure responses. Defaults to `503` and must be in the `400..599` range.
- `^request_timeout_ms <positive-int>`: actor-backed concurrent-mode deadline while waiting for a worker reply. Defaults to `10000` (10 seconds); values must be `1..600000` and non-integers fail at server start.
- `^websocket {^path "/ws" ^handler handler}`

Current ownership and diagnostics model:

- `^concurrent true` routes request execution through actor-backed request
  ports instead of the older extension-local Gene thread pool.
- Concurrent dispatch uses a non-blocking actor-port enqueue. If all request
  workers are saturated, or if `^max_in_flight` has been reached, the server
  returns the configured overload status immediately instead of waiting on actor
  mailbox space. Overload events increment `overload_count` and update the
  redacted `last_error` fields in `http_server_status`.
- The default overload response is status `503` with the small body
  `Service overloaded`. The body is intentionally fixed and does not include
  request bodies, tokens, or headers.
- Worker requests above the current actor-backed HTTP cap are not silent:
  startup logs the clamp through `http_log`, and `http_server_status` exposes
  both `requested_workers` and `effective_workers` plus `worker_clamped`.
- Stopped or invalid actor request ports fail closed with a safe `500` response
  and increment dispatch diagnostics. Status exposes worker health, stopped or
  invalid port counts, active worker count, queued request count from actor
  mailbox snapshots, and in-flight request count.
- Actor-backed request timeouts are cooperative abandonment boundaries. When a
  worker reply is not available within `^request_timeout_ms`, the HTTP request
  is completed with status `504` and body `Async response error: await timed out`,
  the reply future is failed with the same `GENE.ASYNC.TIMEOUT` shape used by
  `await ^timeout`, and runtime tracking is detached so a later stale actor
  reply is ignored. The actor turn may still finish later; Gene does not
  preempt or cancel the running actor handler.
- Handler exceptions and unsupported concurrent response shapes become failed
  actor reply futures and safe HTTP `500` responses. The actor-backed lane stays
  alive for later requests, and `handler_failure_count` plus redacted
  `last_error` fields identify the failure class. This is failure recovery, not
  an actor supervision tree or monitoring API.
- Timeout, overload, dispatch, startup, and handler-failure diagnostics use
  low-overhead counters and the existing `http_log` path. They intentionally
  omit request bodies, secrets, tokens, and full headers.
- SSE and websocket upgrade handling stay on the live server-owner lane because
  they still require the live socket/client object; actor-backed readiness does
  not claim SSE or WebSocket execution.

### `http_server_status`

```gene
(var status (http_server_status))
(println status/status)
(println status/effective_workers)
(println status/overload_count)
```

`http_server_status` returns a map and does not wait on actor workers. The
current helper is process-global because `start_server` does not yet return a
server handle; call it with no arguments. Passing a non-`nil` value returns a
safe diagnostic map with `status` set to `"invalid-handle"` and `status_error`
set to `"GENE.HTTP.STATUS.INVALID_HANDLE"` rather than crashing callers.

Important fields:

- `status`: `ok`, `degraded`, `stopped`, `startup-failed`, or
  `invalid-handle`.
- `server_running`, `port`, `concurrent`, and `actor_backed`.
- `requested_workers`, `effective_workers`, `max_workers`, `worker_clamped`,
  `worker_health`, `worker_port_count`, `stopped_workers`, and
  `invalid_workers`.
- `queue_limit`, `queued_requests`, `active_workers`, `active_requests`,
  `max_in_flight`, and `in_flight`.
- `overload_count`, `timeout_count`, `handler_failure_count`,
  `dispatch_failure_count`, and `startup_failure_count`.
- `last_error_kind`, `last_error`, `last_error_at`, `last_timeout_error`, and
  `last_timeout_at`.
- `redacted`: always `true` for this helper; status values intentionally avoid
  request bodies, secrets, tokens, and full headers.

The helper reports backend-readiness signals for actor-backed request/response
HTTP behind a reverse proxy. It is not a direct edge-hardening status endpoint
and does not imply actor-backed SSE/WebSocket support.

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
