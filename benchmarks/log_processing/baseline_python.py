#!/usr/bin/env python3
"""Baseline: Process 100K log lines in Python — count INFO entries.
Two approaches: string search and parsed/split."""

import time

FILE = "benchmarks/fixtures/sample_100k.glog"

# Approach 1: String search (like 01_string_search.gene)
start = time.monotonic_ns()
count = 0
total = 0
with open(FILE) as f:
    for line in f:
        total += 1
        if " INFO " in line:
            count += 1
elapsed_us = (time.monotonic_ns() - start) / 1000
print(f"Python string search:")
print(f"  Total lines: {total}")
print(f"  INFO lines: {count}")
print(f"  Total time: {elapsed_us:.0f} us")
print(f"  Per line: {elapsed_us / total:.2f} us")
print()

# Approach 2: Split and check field (like 04_parser_loop.gene)
start = time.monotonic_ns()
count = 0
total = 0
with open(FILE) as f:
    for line in f:
        total += 1
        # Quick parse: find the level field (3rd space-delimited token)
        # Line format: (gene/log N LEVEL timestamp "source" "message")
        parts = line.split(None, 4)  # split first 4 whitespace
        if len(parts) >= 4 and parts[2] == "INFO":
            count += 1
elapsed_us = (time.monotonic_ns() - start) / 1000
print(f"Python split+field check:")
print(f"  Total lines: {total}")
print(f"  INFO lines: {count}")
print(f"  Total time: {elapsed_us:.0f} us")
print(f"  Per line: {elapsed_us / total:.2f} us")
