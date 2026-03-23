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
- `^websocket {^path "/ws" ^handler handler}`

The current example is [examples/http_server.gene](../examples/http_server.gene).

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
