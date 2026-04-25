#!/usr/bin/env bash

set -uo pipefail

ROOT_DIR="$(pwd)"
TMP_ROOT="${BENCH_VERIFY_ARTIFACT_DIR:-$(mktemp -d -t gene-http-bench-verify.XXXXXX)}"
KEEP_ARTIFACTS="${BENCH_VERIFY_KEEP_ARTIFACTS:-0}"
RUN_LIVE="${BENCH_VERIFY_LIVE:-0}"
STRICT="${BENCH_STRICT:-0}"

cleanup() {
  if [[ "${KEEP_ARTIFACTS}" != "1" && -n "${BENCH_VERIFY_ARTIFACT_DIR:-}" ]]; then
    return 0
  fi
  if [[ "${KEEP_ARTIFACTS}" != "1" && -d "${TMP_ROOT}" ]]; then
    rm -rf "${TMP_ROOT}"
  fi
}
trap cleanup EXIT

log() {
  printf '%s\n' "$*" >&2
}

fail() {
  log "verify_http_benchmark_artifact: $*"
  exit 1
}

validate_artifact() {
  local artifact_json="$1"
  python3 - "${artifact_json}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print(f"missing artifact JSON: {path}", file=sys.stderr)
    sys.exit(1)

artifact = json.loads(path.read_text(encoding="utf-8"))
missing = []
for key in ["schema_version", "kind", "run_id", "created_at", "completed_at", "status", "environment", "settings", "build", "results", "redaction"]:
    if key not in artifact:
        missing.append(key)
if missing:
    print("missing top-level fields: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)

if artifact["schema_version"] != 1:
    print("unexpected schema_version", file=sys.stderr)
    sys.exit(1)
if artifact["kind"] != "gene-http-ab-benchmark":
    print("unexpected artifact kind", file=sys.stderr)
    sys.exit(1)

settings = artifact["settings"]
for key in ["requests", "concurrency", "endpoint", "baseline", "actor_backed"]:
    if key not in settings:
        print(f"missing settings.{key}", file=sys.stderr)
        sys.exit(1)
if "workers" not in settings["actor_backed"]:
    print("missing settings.actor_backed.workers", file=sys.stderr)
    sys.exit(1)

required_metric_fields = [
    "document_path",
    "concurrency_level",
    "time_taken_seconds",
    "complete_requests",
    "failed_requests",
    "requests_per_second",
    "time_per_request_ms",
    "transfer_rate_kbytes_per_second",
]
for scenario in ["baseline", "actor_backed"]:
    result = artifact["results"].get(scenario)
    if result is None:
        print(f"missing results.{scenario}", file=sys.stderr)
        sys.exit(1)
    for key in ["label", "url", "endpoint", "requests", "concurrency", "exit_code", "timed_out", "status", "raw_output_path", "command", "metrics"]:
        if key not in result:
            print(f"missing results.{scenario}.{key}", file=sys.stderr)
            sys.exit(1)
    if result["status"] == "ok":
        metrics = result["metrics"]
        if not isinstance(metrics, dict):
            print(f"results.{scenario}.metrics is not an object", file=sys.stderr)
            sys.exit(1)
        metric_missing = [key for key in required_metric_fields if key not in metrics]
        if metric_missing:
            print(f"results.{scenario}.metrics missing: {', '.join(metric_missing)}", file=sys.stderr)
            sys.exit(1)
        if metrics["complete_requests"] <= 0:
            print(f"results.{scenario}.metrics.complete_requests must be positive", file=sys.stderr)
            sys.exit(1)

artifact_text = json.dumps(artifact, sort_keys=True)
for forbidden in ["token=secret", "request-body=hidden", "Authorization: Bearer", "Cookie:"]:
    if forbidden in artifact_text:
        print(f"artifact leaked forbidden sample: {forbidden}", file=sys.stderr)
        sys.exit(1)

if artifact["redaction"].get("redacted") is not True:
    print("redaction.redacted must be true", file=sys.stderr)
    sys.exit(1)

print(f"validated {path}")
PY
}

mkdir -p "${TMP_ROOT}"

SAMPLE_DIR="${TMP_ROOT}/sample"
log "verifying fixture-backed dry run -> ${SAMPLE_DIR}"
if ! REQUESTS=8 CONCURRENCY=2 BENCH_DRY_RUN=1 BENCH_ARTIFACT_DIR="${SAMPLE_DIR}" \
  ./scripts/bench_http_ab_demo.sh > "${TMP_ROOT}/dry-run.stdout" 2> "${TMP_ROOT}/dry-run.stderr"; then
  log "--- dry run stdout ---"
  tail -n 80 "${TMP_ROOT}/dry-run.stdout" >&2 2>/dev/null || true
  log "--- dry run stderr ---"
  tail -n 80 "${TMP_ROOT}/dry-run.stderr" >&2 2>/dev/null || true
  fail "fixture-backed dry run failed"
fi
validate_artifact "${SAMPLE_DIR}/http_ab_benchmark.json"

MALFORMED_DIR="${TMP_ROOT}/malformed"
log "verifying malformed fixture rejection -> ${MALFORMED_DIR}"
if REQUESTS=8 CONCURRENCY=2 BENCH_DRY_RUN=1 BENCH_ARTIFACT_DIR="${MALFORMED_DIR}" \
  BENCH_BASELINE_FIXTURE="tests/fixtures/http_ab_malformed_sample.txt" \
  ./scripts/bench_http_ab_demo.sh > "${TMP_ROOT}/malformed.stdout" 2> "${TMP_ROOT}/malformed.stderr"; then
  fail "malformed fixture unexpectedly passed"
fi
if ! grep -q "missing fields" "${TMP_ROOT}/malformed.stderr"; then
  log "--- malformed stderr ---"
  tail -n 80 "${TMP_ROOT}/malformed.stderr" >&2 2>/dev/null || true
  fail "malformed fixture did not report missing fields"
fi

NO_AB_DIR="${TMP_ROOT}/missing-ab"
log "verifying missing ApacheBench is a skipped live run, not a false pass -> ${NO_AB_DIR}"
if ! AB_BIN="${TMP_ROOT}/definitely-missing-ab" BENCH_ARTIFACT_DIR="${NO_AB_DIR}" \
  ./scripts/bench_http_ab_demo.sh > "${TMP_ROOT}/missing-ab.stdout" 2> "${TMP_ROOT}/missing-ab.stderr"; then
  fail "non-strict missing-ab run should write a skipped artifact and exit 0"
fi
python3 - "${NO_AB_DIR}/http_ab_benchmark.json" <<'PY'
import json
import sys
from pathlib import Path
artifact = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if artifact.get("status") != "skipped":
    print(f"expected skipped status, got {artifact.get('status')}", file=sys.stderr)
    sys.exit(1)
if "ApacheBench binary not found" not in (artifact.get("error") or ""):
    print("missing ApacheBench diagnostic", file=sys.stderr)
    sys.exit(1)
print("validated missing-ab skipped artifact")
PY

STRICT_NO_AB_DIR="${TMP_ROOT}/missing-ab-strict"
log "verifying strict missing ApacheBench fails -> ${STRICT_NO_AB_DIR}"
if AB_BIN="${TMP_ROOT}/definitely-missing-ab" BENCH_STRICT=1 BENCH_ARTIFACT_DIR="${STRICT_NO_AB_DIR}" \
  ./scripts/bench_http_ab_demo.sh > "${TMP_ROOT}/missing-ab-strict.stdout" 2> "${TMP_ROOT}/missing-ab-strict.stderr"; then
  fail "strict missing-ab run unexpectedly passed"
fi

if [[ "${RUN_LIVE}" == "1" ]]; then
  LIVE_DIR="${TMP_ROOT}/live"
  if ! command -v ab >/dev/null 2>&1; then
    if [[ "${STRICT}" == "1" ]]; then
      fail "BENCH_VERIFY_LIVE=1 requested but ab is not installed"
    fi
    log "BENCH_VERIFY_LIVE=1 requested but ab is not installed; live check skipped"
  else
    log "verifying bounded live benchmark -> ${LIVE_DIR}"
    if ! REQUESTS="${BENCH_LIVE_REQUESTS:-4}" CONCURRENCY="${BENCH_LIVE_CONCURRENCY:-2}" \
      BENCH_ARTIFACT_DIR="${LIVE_DIR}" ./scripts/bench_http_ab_demo.sh \
      > "${TMP_ROOT}/live.stdout" 2> "${TMP_ROOT}/live.stderr"; then
      log "--- live stdout ---"
      tail -n 80 "${TMP_ROOT}/live.stdout" >&2 2>/dev/null || true
      log "--- live stderr ---"
      tail -n 80 "${TMP_ROOT}/live.stderr" >&2 2>/dev/null || true
      fail "bounded live benchmark failed"
    fi
    validate_artifact "${LIVE_DIR}/http_ab_benchmark.json"
  fi
fi

log "HTTP benchmark artifact verification passed"
printf 'artifact verification workspace: %s\n' "${TMP_ROOT}"
