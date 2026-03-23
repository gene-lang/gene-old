# Benchmarking The HTTP Server

This document shows how to benchmark the current HTTP example and how to test
the optional concurrent server mode implemented in `genex/http`.

This is an implementation note, not a language-spec document.

## Benchmark The Shipped Example

Start the current example server:

```bash
./bin/gene run examples/http_server.gene
```

It listens on `http://127.0.0.1:8086` and exposes:

- `/` -> plain text response
- `/health` -> JSON response

Basic `ab` checks:

```bash
ab -n 100 -c 10 http://127.0.0.1:8086/
ab -n 100 -c 10 http://127.0.0.1:8086/health
```

For a quick latency sample with `curl`:

```bash
time curl -s http://127.0.0.1:8086/ > /dev/null
time curl -s http://127.0.0.1:8086/health > /dev/null
```

## Benchmark Concurrent Mode

`start_server` supports `^concurrent true` and `^workers <n>`, but the shipped
example does not enable that mode. To test it, use a handler that does enough
work to make overlap visible.

Minimal example:

```gene
(import genex/http)

(fn app [req]
  (if (req/path == "/slow")
    (do
      (sleep 2000)
      (respond 200 "slow ok")
    )
  else
    (respond 200 "ok")
  ))

(start_server 8086 app ^concurrent true ^workers 4)
(run_forever)
```

Then compare:

```bash
ab -n 5 -c 1 http://127.0.0.1:8086/slow
ab -n 5 -c 5 http://127.0.0.1:8086/slow
```

The concurrent run should complete materially faster than the sequential one if
the handler work overlaps across workers.

## Notes

- `ab` is fine for quick checks; `wrk` is better for longer runs.
- Benchmark the exact handler shape you care about. The example server is too
  small to say much about real application throughput.
- If results look serialized, verify that your server was started with
  `^concurrent true` and that the handler does non-trivial work.
