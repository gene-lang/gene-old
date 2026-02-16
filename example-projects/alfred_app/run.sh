#!/bin/bash
# Alfred Run Script wrapper
# Executes command via shell, then updates history via Gene
DIR="$HOME/.gene-commander"
GENE="${GENE:-$HOME/gene-workspace/gene/bin/gene}"
APP_DIR="$(dirname "$0")"

mkdir -p "$DIR"
[ -f "$DIR/history.json" ] || echo '[]' > "$DIR/history.json"

# Execute the actual command
eval "$1"

# Update history
$GENE run "$APP_DIR/save_history.gene" "$1"
