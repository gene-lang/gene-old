#!/bin/bash
# Alfred Script Filter wrapper
DIR="$HOME/.gene-commander"
GENE="${GENE:-$HOME/gene-workspace/gene/bin/gene}"
APP_DIR="$(dirname "$0")"

mkdir -p "$DIR"
[ -f "$DIR/history.json" ] || echo '[]' > "$DIR/history.json"

$GENE run "$APP_DIR/filter.gene" "$1"
