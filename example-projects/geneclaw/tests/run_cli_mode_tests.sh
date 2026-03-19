#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP_DIR="$ROOT/example-projects/geneclaw"
GENE_BIN="${GENE_BIN:-$ROOT/bin/gene}"
TMP_DIR="$(mktemp -d)"
HOME_DIR="$TMP_DIR/home"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p \
  "$HOME_DIR/config/llm" \
  "$HOME_DIR/state"

cat > "$HOME_DIR/config/llm/provider.gene" <<'EOF'
"openai"
EOF
cat > "$HOME_DIR/config/llm/openai.gene" <<'EOF'
{^model "gpt-5-mini" ^base_url "" ^timeout_ms "60000"}
EOF
cat > "$HOME_DIR/config/llm/anthropic.gene" <<'EOF'
{^model "claude-sonnet-4-6" ^base_url "" ^timeout_ms "60000"}
EOF
cat > "$HOME_DIR/config/llm/max_steps.gene" <<'EOF'
"6"
EOF
cat > "$HOME_DIR/config/documents.gene" <<'EOF'
{^max_upload_bytes "10485760" ^max_inline_chars "2222" ^max_image_count "4"}
EOF
cat > "$HOME_DIR/state/system_prompt.gene" <<'EOF'
"CLI mode test prompt"
EOF

(
  cd "$APP_DIR"
  env \
    GENECLAW_HOME="$HOME_DIR" \
    GENE_BIN="$GENE_BIN" \
    "$GENE_BIN" run --no-gir-cache tests/test_cli_mode.gene
)
