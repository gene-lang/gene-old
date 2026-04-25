#!/usr/bin/env bash

set -uo pipefail

REQUESTS="${REQUESTS:-20}"
CONCURRENCY="${CONCURRENCY:-10}"
ACTOR_WORKERS="${ACTOR_WORKERS:-8}"
SLEEP_MS="${SLEEP_MS:-200}"
BASELINE_PORT="${BASELINE_PORT:-8088}"
ACTOR_PORT="${ACTOR_PORT:-8089}"
ENDPOINT="${ENDPOINT:-/slow}"
BENCH_DRY_RUN="${BENCH_DRY_RUN:-0}"
BENCH_STRICT="${BENCH_STRICT:-0}"
BENCH_MARKDOWN="${BENCH_MARKDOWN:-1}"
BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS:-60}"
SERVER_START_TIMEOUT_SECONDS="${SERVER_START_TIMEOUT_SECONDS:-10}"
AB_BIN="${AB_BIN:-ab}"
RUN_ID="${BENCH_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
ARTIFACT_DIR="${BENCH_ARTIFACT_DIR:-benchmark-results/http-ab-${RUN_ID}}"
BASELINE_FIXTURE="${BENCH_BASELINE_FIXTURE:-tests/fixtures/http_ab_baseline_sample.txt}"
ACTOR_FIXTURE="${BENCH_ACTOR_FIXTURE:-tests/fixtures/http_ab_actor_sample.txt}"
BUILD_COMMAND="${BUILD_COMMAND:-nim c -o:bin/gene src/gene.nim}"

JSON_PATH="${ARTIFACT_DIR}/http_ab_benchmark.json"
MD_PATH="${ARTIFACT_DIR}/http_ab_benchmark.md"
RUNS_MANIFEST="${ARTIFACT_DIR}/runs.tsv"
SERVERS_MANIFEST="${ARTIFACT_DIR}/servers.tsv"
DIAGNOSTICS_LOG="${ARTIFACT_DIR}/diagnostics.log"
BUILD_LOG="${ARTIFACT_DIR}/build.log"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_STATUS="ok"
RUN_ERROR=""
BUILD_EXIT_CODE=""
BUILD_SKIPPED="false"
SERVER_PIDS=()

mkdir -p "${ARTIFACT_DIR}"
printf 'scenario\tlabel\turl\tendpoint\trequests\tconcurrency\texit_code\ttimed_out\tstatus\traw_output_path\tcommand\n' > "${RUNS_MANIFEST}"
printf 'scenario\texample\tport\turl\tpid\tlog_path\texit_code\tstatus\tmessage\n' > "${SERVERS_MANIFEST}"
: > "${DIAGNOSTICS_LOG}"

iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

log_diag() {
  local message="$*"
  printf '%s\t%s\n' "$(iso_now)" "${message}" >> "${DIAGNOSTICS_LOG}"
  printf '%s\n' "${message}" >&2
}

cleanup() {
  local pid
  for pid in "${SERVER_PIDS[@]:-}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT INT TERM

append_run() {
  local scenario="$1"
  local label="$2"
  local url="$3"
  local exit_code="$4"
  local timed_out="$5"
  local status="$6"
  local raw_path="$7"
  local command_text="$8"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${scenario}" "${label}" "${url}" "${ENDPOINT}" "${REQUESTS}" "${CONCURRENCY}" \
    "${exit_code}" "${timed_out}" "${status}" "${raw_path}" "${command_text}" >> "${RUNS_MANIFEST}"
}

append_server() {
  local scenario="$1"
  local example="$2"
  local port="$3"
  local url="$4"
  local pid="$5"
  local log_path="$6"
  local exit_code="$7"
  local status="$8"
  local message="$9"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${scenario}" "${example}" "${port}" "${url}" "${pid}" "${log_path}" \
    "${exit_code}" "${status}" "${message}" >> "${SERVERS_MANIFEST}"
}

copy_fixture_run() {
  local scenario="$1"
  local label="$2"
  local fixture="$3"
  local url="$4"
  local raw_path="${ARTIFACT_DIR}/${scenario}.ab.txt"

  if [[ ! -f "${fixture}" ]]; then
    RUN_STATUS="failed"
    RUN_ERROR="missing fixture: ${fixture}"
    log_diag "missing fixture for ${scenario}: ${fixture}"
    append_run "${scenario}" "${label}" "${url}" 1 0 "failed" "${raw_path}" "fixture:${fixture}"
    return 1
  fi

  cp "${fixture}" "${raw_path}"
  append_run "${scenario}" "${label}" "${url}" 0 0 "ok" "${raw_path}" "fixture:${fixture}"
  return 0
}

run_command_with_timeout() {
  local timeout_seconds="$1"
  local raw_path="$2"
  shift 2

  python3 - "$timeout_seconds" "$raw_path" "$@" <<'PY'
import subprocess
import sys

try:
    timeout_seconds = float(sys.argv[1])
    raw_path = sys.argv[2]
    command = sys.argv[3:]
    completed = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout_seconds,
    )
    with open(raw_path, "w", encoding="utf-8") as handle:
        handle.write(completed.stdout or "")
    sys.exit(completed.returncode)
except subprocess.TimeoutExpired as exc:
    with open(raw_path, "w", encoding="utf-8") as handle:
        if exc.stdout:
            handle.write(exc.stdout if isinstance(exc.stdout, str) else exc.stdout.decode("utf-8", "replace"))
        if exc.stderr:
            handle.write(exc.stderr if isinstance(exc.stderr, str) else exc.stderr.decode("utf-8", "replace"))
        handle.write("\nGENE_BENCH_TIMEOUT: command exceeded timeout\n")
    sys.exit(124)
PY
}

run_ab_pass() {
  local scenario="$1"
  local label="$2"
  local url="$3"
  local raw_path="${ARTIFACT_DIR}/${scenario}.ab.txt"
  local target="${url}${ENDPOINT}"
  local command_text="${AB_BIN} -n ${REQUESTS} -c ${CONCURRENCY} ${target}"

  log_diag "running ${label}: ${command_text}"
  run_command_with_timeout "${BENCH_TIMEOUT_SECONDS}" "${raw_path}" \
    "${AB_BIN}" -n "${REQUESTS}" -c "${CONCURRENCY}" "${target}"
  local exit_code=$?
  local timed_out=0
  local status="ok"
  if [[ ${exit_code} -eq 124 ]]; then
    timed_out=1
    status="timeout"
    RUN_STATUS="failed"
    RUN_ERROR="${label} timed out"
  elif [[ ${exit_code} -ne 0 ]]; then
    status="failed"
    RUN_STATUS="failed"
    RUN_ERROR="${label} exited ${exit_code}"
  fi

  append_run "${scenario}" "${label}" "${url}" "${exit_code}" "${timed_out}" "${status}" "${raw_path}" "${command_text}"
  return "${exit_code}"
}

wait_for_server() {
  local url="$1"
  local log_file="$2"
  local deadline=$(( $(date +%s) + SERVER_START_TIMEOUT_SECONDS ))
  local body

  if ! command -v curl >/dev/null 2>&1; then
    log_diag "curl is required to wait for demo server readiness"
    return 1
  fi

  while [[ $(date +%s) -le ${deadline} ]]; do
    body="$(curl -fsS "${url}/health" 2>/dev/null || true)"
    if [[ "${body}" == *"ok"* ]]; then
      return 0
    fi
    sleep 0.2
  done

  log_diag "server did not become ready: ${url}; log=${log_file}"
  tail -n 50 "${log_file}" >&2 2>/dev/null || true
  return 1
}

start_server() {
  local scenario="$1"
  local example="$2"
  local port="$3"
  local label="$4"
  local url="http://127.0.0.1:${port}"
  local log_file="${ARTIFACT_DIR}/${scenario}-server.log"

  log_diag "starting ${label} from ${example} on ${url}"
  HTTP_AB_PORT="${port}" \
  HTTP_AB_SLEEP_MS="${SLEEP_MS}" \
  HTTP_AB_ACTOR_WORKERS="${ACTOR_WORKERS}" \
    ./bin/gene run "${example}" > "${log_file}" 2>&1 &
  local pid=$!
  SERVER_PIDS+=("${pid}")

  if wait_for_server "${url}" "${log_file}"; then
    append_server "${scenario}" "${example}" "${port}" "${url}" "${pid}" "${log_file}" "" "running" "ready"
    printf '%s\n' "${url}"
    return 0
  fi

  local exit_code=""
  if ! kill -0 "${pid}" 2>/dev/null; then
    wait "${pid}" 2>/dev/null
    exit_code=$?
  fi
  append_server "${scenario}" "${example}" "${port}" "${url}" "${pid}" "${log_file}" "${exit_code}" "failed" "readiness timeout or invalid /health output"
  return 1
}

stop_server() {
  local pid="$1"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
}

write_artifacts() {
  local completed_at
  completed_at="$(iso_now)"
  export REQUESTS CONCURRENCY ACTOR_WORKERS SLEEP_MS BASELINE_PORT ACTOR_PORT ENDPOINT
  export BENCH_DRY_RUN BENCH_TIMEOUT_SECONDS SERVER_START_TIMEOUT_SECONDS RUN_ID ARTIFACT_DIR
  export STARTED_AT completed_at RUN_STATUS RUN_ERROR BUILD_COMMAND BUILD_LOG BUILD_EXIT_CODE BUILD_SKIPPED
  export AB_BIN JSON_PATH MD_PATH BENCH_MARKDOWN DIAGNOSTICS_LOG

  python3 - "${RUNS_MANIFEST}" "${SERVERS_MANIFEST}" <<'PY'
import csv
import json
import os
import platform
import re
import subprocess
import sys
from pathlib import Path

runs_manifest = Path(sys.argv[1])
servers_manifest = Path(sys.argv[2])
json_path = Path(os.environ["JSON_PATH"])
md_path = Path(os.environ["MD_PATH"])

def read_tsv(path):
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))

def command_output(command):
    try:
        completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=5)
        if completed.returncode == 0:
            return completed.stdout.strip().splitlines()[0] if completed.stdout.strip() else ""
        return ""
    except Exception:
        return ""

def parse_float(text):
    return float(text.replace(",", ""))

def parse_int(text):
    return int(text.replace(",", ""))

def parse_ab_output(text):
    metrics = {}
    line_hits = {}
    lines = text.splitlines()

    patterns = [
        ("server_software", r"^Server Software:\s*(.*)$", str),
        ("server_hostname", r"^Server Hostname:\s*(.+)$", str),
        ("server_port", r"^Server Port:\s*(\d+)\s*$", parse_int),
        ("document_path", r"^Document Path:\s*(.+)$", str),
        ("document_length_bytes", r"^Document Length:\s*([\d,]+)\s+bytes", parse_int),
        ("concurrency_level", r"^Concurrency Level:\s*([\d,]+)\s*$", parse_int),
        ("time_taken_seconds", r"^Time taken for tests:\s*([\d.,]+)\s+seconds", parse_float),
        ("complete_requests", r"^Complete requests:\s*([\d,]+)\s*$", parse_int),
        ("failed_requests", r"^Failed requests:\s*([\d,]+)\s*$", parse_int),
        ("total_transferred_bytes", r"^Total transferred:\s*([\d,]+)\s+bytes", parse_int),
        ("html_transferred_bytes", r"^HTML transferred:\s*([\d,]+)\s+bytes", parse_int),
        ("requests_per_second", r"^Requests per second:\s*([\d.,]+)\s+\[#/sec\]", parse_float),
        ("transfer_rate_kbytes_per_second", r"^Transfer rate:\s*([\d.,]+)\s+\[Kbytes/sec\]", parse_float),
    ]

    for idx, line in enumerate(lines, start=1):
        for key, pattern, converter in patterns:
            if key in metrics:
                continue
            match = re.match(pattern, line)
            if match:
                value = match.group(1).strip()
                metrics[key] = converter(value)
                line_hits[key] = idx
                break
        if line.startswith("Time per request:"):
            value_match = re.search(r"Time per request:\s*([\d.,]+)\s+\[ms\]", line)
            if value_match:
                value = parse_float(value_match.group(1))
                if "across all concurrent requests" in line:
                    metrics["time_per_request_across_all_ms"] = value
                    line_hits["time_per_request_across_all_ms"] = idx
                elif "time_per_request_ms" not in metrics:
                    metrics["time_per_request_ms"] = value
                    line_hits["time_per_request_ms"] = idx

    required = [
        "document_path",
        "concurrency_level",
        "time_taken_seconds",
        "complete_requests",
        "failed_requests",
        "requests_per_second",
        "time_per_request_ms",
        "transfer_rate_kbytes_per_second",
    ]
    missing = [key for key in required if key not in metrics]
    if missing:
        return None, {
            "message": "ApacheBench output is missing required fields",
            "missing_fields": missing,
            "line_count": len(lines),
        }

    metrics["source_line_numbers"] = line_hits
    return metrics, None

def parse_bool(value):
    return str(value).lower() in {"1", "true", "yes", "on"}

runs = read_tsv(runs_manifest)
servers = read_tsv(servers_manifest)
diagnostics = []
diag_path = Path(os.environ["DIAGNOSTICS_LOG"])
if diag_path.exists():
    diagnostics = [line.rstrip("\n") for line in diag_path.read_text(encoding="utf-8").splitlines() if line.strip()]

parse_errors = []
results = {}
for row in runs:
    scenario = row["scenario"]
    raw_path = Path(row["raw_output_path"])
    status = row["status"]
    metrics = None
    parse_error = None
    if status in {"ok", "failed", "timeout"} and raw_path.exists():
        text = raw_path.read_text(encoding="utf-8", errors="replace")
        metrics, parse_error = parse_ab_output(text)
        if parse_error is not None:
            parse_errors.append({"scenario": scenario, "raw_output_path": str(raw_path), **parse_error})
    elif status == "ok":
        parse_error = {"message": "raw output path does not exist", "raw_output_path": str(raw_path)}
        parse_errors.append({"scenario": scenario, **parse_error})

    results[scenario] = {
        "label": row["label"],
        "url": row["url"],
        "endpoint": row["endpoint"],
        "requests": int(row["requests"]),
        "concurrency": int(row["concurrency"]),
        "exit_code": int(row["exit_code"]) if row["exit_code"] else None,
        "timed_out": row["timed_out"] == "1",
        "status": status,
        "raw_output_path": str(raw_path),
        "command": row["command"],
        "metrics": metrics,
        "parse_error": parse_error,
    }

run_status = os.environ.get("RUN_STATUS", "ok")
if parse_errors:
    run_status = "failed"

artifact = {
    "schema_version": 1,
    "kind": "gene-http-ab-benchmark",
    "run_id": os.environ["RUN_ID"],
    "created_at": os.environ["STARTED_AT"],
    "completed_at": os.environ["completed_at"],
    "status": run_status,
    "error": os.environ.get("RUN_ERROR") or None,
    "dry_run": parse_bool(os.environ.get("BENCH_DRY_RUN", "0")),
    "environment": {
        "os": platform.platform(),
        "machine": platform.machine(),
        "python_version": platform.python_version(),
        "cpu_count": os.cpu_count(),
        "nim_version": command_output(["nim", "--version"]),
        "ab_path": command_output(["bash", "-lc", f"command -v {os.environ.get('AB_BIN', 'ab')} 2>/dev/null"]),
        "gene_binary": "./bin/gene",
    },
    "settings": {
        "requests": int(os.environ["REQUESTS"]),
        "concurrency": int(os.environ["CONCURRENCY"]),
        "endpoint": os.environ["ENDPOINT"],
        "sleep_ms": int(os.environ["SLEEP_MS"]),
        "benchmark_timeout_seconds": int(os.environ["BENCH_TIMEOUT_SECONDS"]),
        "server_start_timeout_seconds": int(os.environ["SERVER_START_TIMEOUT_SECONDS"]),
        "baseline": {
            "example": "examples/http_ab_demo.gene",
            "port": int(os.environ["BASELINE_PORT"]),
            "url": f"http://127.0.0.1:{os.environ['BASELINE_PORT']}",
            "workers": 1,
            "concurrent": False,
        },
        "actor_backed": {
            "example": "examples/http_ab_actor_demo.gene",
            "port": int(os.environ["ACTOR_PORT"]),
            "url": f"http://127.0.0.1:{os.environ['ACTOR_PORT']}",
            "workers": int(os.environ["ACTOR_WORKERS"]),
            "concurrent": True,
        },
    },
    "build": {
        "command": os.environ["BUILD_COMMAND"],
        "exit_code": int(os.environ["BUILD_EXIT_CODE"]) if os.environ.get("BUILD_EXIT_CODE") else None,
        "skipped": parse_bool(os.environ.get("BUILD_SKIPPED", "false")),
        "log_path": os.environ["BUILD_LOG"],
    },
    "servers": servers,
    "results": results,
    "diagnostics": diagnostics,
    "parse_errors": parse_errors,
    "redaction": {
        "redacted": True,
        "policy": "Artifacts capture benchmark settings, metrics, exit codes, timestamps, and log paths only; request bodies, secrets, tokens, and full headers are omitted by default.",
    },
}

json_path.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n", encoding="utf-8")

if parse_bool(os.environ.get("BENCH_MARKDOWN", "1")):
    lines = [
        "# Gene HTTP ApacheBench Artifact Summary",
        "",
        f"- Run ID: `{artifact['run_id']}`",
        f"- Status: `{artifact['status']}`",
        f"- Created: `{artifact['created_at']}`",
        f"- Completed: `{artifact['completed_at']}`",
        f"- Dry run: `{str(artifact['dry_run']).lower()}`",
        f"- Requests: `{artifact['settings']['requests']}`",
        f"- Concurrency: `{artifact['settings']['concurrency']}`",
        f"- Endpoint: `{artifact['settings']['endpoint']}`",
        f"- Actor workers: `{artifact['settings']['actor_backed']['workers']}`",
        "",
        "## Results",
        "",
        "| Scenario | Status | Exit | Complete | Failed | RPS | Mean ms/request | Raw output |",
        "|---|---:|---:|---:|---:|---:|---:|---|",
    ]
    for scenario in ["baseline", "actor_backed"]:
        result = results.get(scenario, {})
        metrics = result.get("metrics") or {}
        def fmt(value):
            return "—" if value is None else str(value)
        lines.append(
            "| {scenario} | {status} | {exit_code} | {complete} | {failed} | {rps} | {tpr} | `{raw}` |".format(
                scenario=scenario,
                status=result.get("status", "missing"),
                exit_code=fmt(result.get("exit_code")),
                complete=fmt(metrics.get("complete_requests")),
                failed=fmt(metrics.get("failed_requests")),
                rps=fmt(metrics.get("requests_per_second")),
                tpr=fmt(metrics.get("time_per_request_ms")),
                raw=result.get("raw_output_path", ""),
            )
        )
    lines.extend([
        "",
        "## Interpretation",
        "",
        "Use this artifact for comparative evidence on the same machine and settings. Do not treat a specific requests-per-second value as a portable pass/fail threshold.",
        "",
        "## Redaction",
        "",
        artifact["redaction"]["policy"],
        "",
    ])
    if parse_errors:
        lines.extend(["## Parse Errors", ""])
        for error in parse_errors:
            lines.append(f"- `{error['scenario']}` missing `{', '.join(error.get('missing_fields', []))}` in `{error.get('raw_output_path')}`")
        lines.append("")
    md_path.write_text("\n".join(lines), encoding="utf-8")

if parse_errors:
    for error in parse_errors:
        print(
            f"ab parse error for {error['scenario']}: missing fields {', '.join(error.get('missing_fields', []))} "
            f"in {error.get('raw_output_path')} (lines={error.get('line_count')})",
            file=sys.stderr,
        )
    sys.exit(2)
PY
}

finish() {
  local artifact_rc=0
  write_artifacts || artifact_rc=$?
  if [[ ${artifact_rc} -ne 0 ]]; then
    return "${artifact_rc}"
  fi
  printf 'benchmark artifact: %s\n' "${JSON_PATH}"
  if [[ "${BENCH_MARKDOWN}" != "0" ]]; then
    printf 'benchmark summary: %s\n' "${MD_PATH}"
  fi
  if [[ "${RUN_STATUS}" == "failed" ]]; then
    return 1
  fi
  return 0
}

if [[ "${BENCH_DRY_RUN}" == "1" ]]; then
  BUILD_SKIPPED="true"
  log_diag "BENCH_DRY_RUN=1: parsing tracked fixtures without building, starting servers, or requiring ApacheBench"
  copy_fixture_run "baseline" "blocking baseline" "${BASELINE_FIXTURE}" "http://127.0.0.1:${BASELINE_PORT}" || true
  copy_fixture_run "actor_backed" "actor-backed concurrent server" "${ACTOR_FIXTURE}" "http://127.0.0.1:${ACTOR_PORT}" || true
  finish
  exit $?
fi

if ! command -v "${AB_BIN}" >/dev/null 2>&1; then
  RUN_STATUS="skipped"
  RUN_ERROR="ApacheBench binary not found: ${AB_BIN}"
  BUILD_SKIPPED="true"
  log_diag "ApacheBench binary not found: ${AB_BIN}; live benchmark skipped"
  finish
  finish_rc=$?
  if [[ "${BENCH_STRICT}" == "1" ]]; then
    exit 1
  fi
  exit "${finish_rc}"
fi

if [[ "${BENCH_SKIP_BUILD:-0}" == "1" ]]; then
  BUILD_SKIPPED="true"
  log_diag "BENCH_SKIP_BUILD=1: using existing ./bin/gene"
else
  mkdir -p bin
  log_diag "building Gene binary: ${BUILD_COMMAND}"
  # shellcheck disable=SC2086
  ${BUILD_COMMAND} > "${BUILD_LOG}" 2>&1
  BUILD_EXIT_CODE=$?
  if [[ ${BUILD_EXIT_CODE} -ne 0 ]]; then
    RUN_STATUS="failed"
    RUN_ERROR="Gene build failed with exit ${BUILD_EXIT_CODE}"
    log_diag "Gene build failed; log=${BUILD_LOG}"
    finish
    exit 1
  fi
fi

baseline_url="$(start_server "baseline" "examples/http_ab_demo.gene" "${BASELINE_PORT}" "blocking baseline")"
if [[ $? -ne 0 ]]; then
  RUN_STATUS="failed"
  RUN_ERROR="baseline server failed to start"
  finish
  exit 1
fi
run_ab_pass "baseline" "blocking baseline" "${baseline_url}" || true
cleanup
SERVER_PIDS=()

actor_url="$(start_server "actor_backed" "examples/http_ab_actor_demo.gene" "${ACTOR_PORT}" "actor-backed concurrent server")"
if [[ $? -ne 0 ]]; then
  RUN_STATUS="failed"
  RUN_ERROR="actor-backed server failed to start"
  finish
  exit 1
fi
run_ab_pass "actor_backed" "actor-backed concurrent server" "${actor_url}" || true
cleanup
SERVER_PIDS=()

finish
exit $?
