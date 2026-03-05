#!/usr/bin/env node

// Compute next fire time for a 5-field cron expression.
// Usage: node cron_next.mjs '<cron_expr>' [base_ms]
// Output: JSON  {"ok":true,"next_run_ms":...,"next_run_iso":"..."}

function parseCronField(field, min, max) {
  const values = new Set();
  for (const part of field.split(',')) {
    const stepMatch = part.match(/^(.+)\/(\d+)$/);
    let range, step = 1;
    if (stepMatch) {
      range = stepMatch[1];
      step = parseInt(stepMatch[2], 10);
    } else {
      range = part;
    }

    let start, end;
    if (range === '*') {
      start = min; end = max;
    } else if (range.includes('-')) {
      const [a, b] = range.split('-');
      start = parseInt(a, 10); end = parseInt(b, 10);
    } else {
      start = parseInt(range, 10); end = start;
    }

    for (let i = start; i <= end; i += step) {
      if (i >= min && i <= max) values.add(i);
    }
  }
  return values;
}

function nextCronRun(cronExpr, baseMs) {
  const parts = cronExpr.trim().split(/\s+/);
  if (parts.length !== 5) {
    throw new Error('Cron expression must have 5 fields: minute hour dom month dow');
  }

  const minutes = parseCronField(parts[0], 0, 59);
  const hours   = parseCronField(parts[1], 0, 23);
  const doms    = parseCronField(parts[2], 1, 31);
  const months  = parseCronField(parts[3], 1, 12);
  const dows    = parseCronField(parts[4], 0, 7);

  // Normalize: 7 is also Sunday
  if (dows.has(7)) { dows.add(0); dows.delete(7); }

  const domRestricted = parts[2] !== '*';
  const dowRestricted = parts[4] !== '*';

  const d = new Date(baseMs);
  d.setSeconds(0, 0);
  d.setMinutes(d.getMinutes() + 1);

  // Search up to ~2 years of minutes
  const maxIter = 2 * 366 * 24 * 60;

  for (let i = 0; i < maxIter; i++) {
    if (!months.has(d.getMonth() + 1)) {
      d.setMonth(d.getMonth() + 1, 1);
      d.setHours(0, 0, 0, 0);
      continue;
    }

    // Standard cron: if BOTH dom and dow are restricted, match when EITHER hits
    const domMatch = doms.has(d.getDate());
    const dowMatch = dows.has(d.getDay());
    let dayOk;
    if (domRestricted && dowRestricted) {
      dayOk = domMatch || dowMatch;
    } else if (domRestricted) {
      dayOk = domMatch;
    } else if (dowRestricted) {
      dayOk = dowMatch;
    } else {
      dayOk = true;
    }

    if (!dayOk) {
      d.setDate(d.getDate() + 1);
      d.setHours(0, 0, 0, 0);
      continue;
    }

    if (!hours.has(d.getHours())) {
      d.setHours(d.getHours() + 1, 0, 0, 0);
      continue;
    }

    if (!minutes.has(d.getMinutes())) {
      d.setMinutes(d.getMinutes() + 1, 0, 0);
      continue;
    }

    return d.getTime();
  }

  throw new Error('No matching cron time found within search window');
}

// --- Main ---
const cronExpr = process.argv[2];
const baseMs = process.argv[3] ? parseInt(process.argv[3], 10) : Date.now();

if (!cronExpr) {
  process.stdout.write(JSON.stringify({ ok: false, error: 'Usage: node cron_next.mjs <cron_expr> [base_ms]' }));
  process.exit(1);
}

try {
  const nextMs = nextCronRun(cronExpr, baseMs);
  process.stdout.write(JSON.stringify({ ok: true, next_run_ms: nextMs, next_run_iso: new Date(nextMs).toISOString() }));
} catch (err) {
  process.stdout.write(JSON.stringify({ ok: false, error: err.message }));
  process.exit(1);
}

