# Benchmarking The HTTP Server

This document shows how to benchmark the blocking HTTP demo and the
actor-backed concurrent HTTP demo implemented through `genex/http`.

This is an implementation note, not a language-spec document. The benchmark
runner records durable evidence for review; it does **not** define a portable
requests-per-second pass/fail threshold.

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

## Durable Actor-Backed Benchmark Artifacts

The repository includes a blocking baseline demo, an actor-backed concurrent
variant, a benchmark artifact writer, and a fixture-based verifier:

```bash
./bin/gene run examples/http_ab_demo.gene
./bin/gene run examples/http_ab_actor_demo.gene
REQUESTS=40 CONCURRENCY=8 ./scripts/bench_http_ab_demo.sh
./scripts/verify_http_benchmark_artifact.sh
```

By default the runner writes to an ignored local directory:

```text
benchmark-results/http-ab-<UTC timestamp>/
  http_ab_benchmark.json
  http_ab_benchmark.md
  baseline.ab.txt
  actor_backed.ab.txt
  baseline-server.log
  actor_backed-server.log
  build.log
```

Use `BENCH_ARTIFACT_DIR` to choose a different destination:

```bash
BENCH_ARTIFACT_DIR=/tmp/gene-http-bench REQUESTS=80 CONCURRENCY=16 \
  ./scripts/bench_http_ab_demo.sh
```

The JSON artifact is the source of truth. It includes:

- `schema_version`, `kind`, `run_id`, `created_at`, `completed_at`, `status`,
  and `dry_run`.
- `environment`: OS, machine, Python version, CPU count, Nim version when
  available, `ab` path when available, and the Gene binary path.
- `settings`: request count, concurrency, endpoint, demo sleep duration,
  benchmark timeout, server start timeout, baseline port/example, and
  actor-backed port/example/effective worker setting.
- `build`: build command, exit code, skipped flag, and build log path.
- `servers`: server example, port, URL, process id, log path, readiness status,
  and startup failure metadata when applicable.
- `results.baseline` and `results.actor_backed`: command, exit code, timeout
  flag, raw `ab` output path, parsed metrics, and parse errors when output is
  malformed.
- `diagnostics` and `parse_errors`: timestamped runner decisions and parser
  failures suitable for a future agent to inspect.
- `redaction`: the artifact policy. Request bodies, secrets, tokens, and full
  headers are not captured by default.

The Markdown file is a human summary derived from the JSON and should not be
used as the only machine-readable evidence.

## Fixture And CI-Style Verification

Use dry-run mode to test artifact generation and parser/schema validation without
ApacheBench, without starting servers, and without reading untracked terminal
output:

```bash
REQUESTS=8 CONCURRENCY=2 BENCH_DRY_RUN=1 ./scripts/bench_http_ab_demo.sh
./scripts/verify_http_benchmark_artifact.sh
```

Dry-run mode reads only tracked fixtures:

- `tests/fixtures/http_ab_baseline_sample.txt`
- `tests/fixtures/http_ab_actor_sample.txt`
- `tests/fixtures/http_ab_malformed_sample.txt`

The verifier checks that the valid fixtures produce a schema-complete JSON
artifact, that the malformed fixture is rejected with missing-field diagnostics,
and that a missing `ab` binary produces a skipped artifact rather than a false
live benchmark pass. Set `BENCH_VERIFY_LIVE=1` to add a very small live run when
`ab` is installed; with `BENCH_STRICT=1`, missing `ab` fails instead of skipping.

## Runtime Settings

Common environment overrides:

| Variable | Default | Meaning |
|---|---:|---|
| `REQUESTS` | `20` | Requests passed to `ab -n`. |
| `CONCURRENCY` | `10` | Concurrency passed to `ab -c`. |
| `ACTOR_WORKERS` | `8` | Actor-backed HTTP workers for `http_ab_actor_demo.gene`. |
| `SLEEP_MS` | `200` | Blocking work duration in both demos' `/slow` handler. |
| `BASELINE_PORT` | `8088` | Port for the blocking baseline demo. |
| `ACTOR_PORT` | `8089` | Port for the actor-backed demo. |
| `ENDPOINT` | `/slow` | Endpoint benchmarked by `ab`. |
| `BENCH_TIMEOUT_SECONDS` | `60` | Per-`ab` process timeout. |
| `SERVER_START_TIMEOUT_SECONDS` | `10` | Readiness timeout for `/health`. |
| `BENCH_ARTIFACT_DIR` | `benchmark-results/http-ab-<timestamp>` | Artifact directory. |
| `BENCH_DRY_RUN` | `0` | Parse tracked fixtures instead of running a live benchmark. |
| `BENCH_MARKDOWN` | `1` | Write the Markdown summary when non-zero. |
| `BENCH_STRICT` | `0` | Treat missing `ab` as failure rather than a skipped live benchmark. |

## Interpretation Guidance

Compare baseline and actor-backed artifacts only when they were produced on the
same machine with the same `REQUESTS`, `CONCURRENCY`, `SLEEP_MS`, endpoint, and
Gene build. The actor-backed demo is expected to improve front-door latency when
blocking handler work can overlap across workers, but exact throughput depends on
hardware, OS scheduling, local load, Nim build mode, and ApacheBench behavior.

Do not add a hard RPS or latency threshold to CI from these local artifacts.
Regression review should look for directional changes, failed requests,
timeouts, parser failures, worker/queue settings, and whether the artifact was a
fixture dry-run or a real live run.

## Notes

- `ab` is fine for quick bounded checks; `wrk` or a purpose-built load tool is
  better for longer controlled benchmark campaigns.
- Benchmark the exact handler shape you care about. The example server is too
  small to represent real application throughput.
- If the actor-backed demo does not improve front-door latency, verify that it
  called `gene/actor/enable`, that `ACTOR_WORKERS` is within the supported HTTP
  worker cap, and that the JSON artifact shows the intended request/concurrency
  settings.
