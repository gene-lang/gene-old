#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP_DIR="$ROOT/example-projects/geneclaw"
GENE_BIN="$ROOT/bin/gene"
TMP_DIR="$(mktemp -d)"
HOME_DIR="$TMP_DIR/home"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p \
  "$HOME_DIR/config/llm" \
  "$HOME_DIR/workspace/sessions"

cat > "$HOME_DIR/config/llm/provider.gene" <<'EOF'
"{ENV:GENECLAW_TEST_PROVIDER:openai}"
EOF
cat > "$HOME_DIR/config/llm/openai.gene" <<'EOF'
{^model "{ENV:GENECLAW_TEST_MODEL:gpt-5-mini}" ^base_url "{ENV:OPENAI_BASE_URL:}" ^timeout_ms "{ENV:OPENAI_TIMEOUT_MS:60000}"}
EOF
cat > "$HOME_DIR/config/llm/anthropic.gene" <<'EOF'
{^model "{ENV:GENECLAW_TEST_ANTHROPIC_MODEL:claude-sonnet-4-6}" ^base_url "{ENV:ANTHROPIC_BASE_URL:}" ^timeout_ms "{ENV:ANTHROPIC_TIMEOUT_MS:60000}"}
EOF
cat > "$HOME_DIR/config/llm/max_steps.gene" <<'EOF'
"{ENV:GENECLAW_TEST_MAX_STEPS:9}"
EOF
cat > "$HOME_DIR/config/documents.gene" <<'EOF'
{^max_upload_bytes "{ENV:GENECLAW_DOCUMENT_MAX_UPLOAD_BYTES:10485760}" ^max_inline_chars "{ENV:GENECLAW_TEST_INLINE:2222}" ^max_image_count "{ENV:GENECLAW_IMAGE_MAX_COUNT:4}"}
EOF
cat > "$HOME_DIR/workspace/system_prompt.gene" <<'EOF'
"Prompt {ENV:GENECLAW_TEST_PROVIDER:openai} / {ENV:GENECLAW_TEST_MODEL:gpt-5-mini} / {ENV:GENECLAW_TEST_PROVIDER:openai}"
EOF

run_test() {
  local test_file="$1"
  shift
  (
    cd "$APP_DIR"
    env \
      GENECLAW_HOME="$HOME_DIR" \
      GENECLAW_TEST_PROVIDER="anthropic" \
      GENECLAW_TEST_MODEL="gpt-5.1-mini" \
      GENECLAW_TEST_ANTHROPIC_MODEL="claude-sonnet-4-6" \
      GENECLAW_TEST_MAX_STEPS="9" \
      GENECLAW_TEST_INLINE="2222" \
      ANTHROPIC_OAUTH_TOKEN="oauth-home-token" \
      "$@" \
      "$GENE_BIN" run "$test_file"
  )
}

run_test tests/test_config_schema_helpers.gene
run_test tests/test_home_storage_config.gene
run_test tests/test_home_storage_write.gene
run_test tests/test_home_storage_read.gene
