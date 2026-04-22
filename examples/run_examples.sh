#!/usr/bin/env bash

set -euo pipefail

examples=(
  examples/hello_world.gene
  examples/print.gene
  examples/cmd_args.gene
  examples/env.gene
  examples/json.gene
  examples/datetime.gene
  examples/fib.gene
  examples/async.gene
  examples/io.gene
  examples/oop.gene
  examples/sample_typed.gene
  examples/process_management.gene
)

for file in "${examples[@]}"; do
  echo '$' "$file"
  ./bin/gene run "$file"
  echo
  echo
done
