# Gene Commander — Alfred Workflow

A generic Alfred workflow powered by Gene with command history and filtering.

## Files

- `filter.gene` — Script Filter: loads history, filters by query, outputs Alfred JSON
- `save_history.gene` — Saves/updates command in history file
- `filter.sh` — Shell wrapper for filter (bootstraps history file)
- `run.sh` — Shell wrapper: executes command via `sh`, then saves to history via Gene

## Setup

### 1. Create Alfred workflow

1. Alfred Preferences → Workflows → `+` → Blank Workflow
2. Name: **Gene Commander**, Bundle ID: `com.gene.commander`

### 2. Add nodes

**Hotkey Trigger:**
- Triggers → Hotkey → set shortcut (e.g. `⌥ Space`)

**Script Filter:**
- Inputs → Script Filter
- Keyword: `gc` (optional, for keyword access too)
- Language: `/bin/bash`
- Script:
  ```bash
  ~/gene-workspace/gene/example-projects/alfred_app/filter.sh "{query}"
  ```
- "Alfred filters results" = **OFF**

**Run Script:**
- Actions → Run Script
- Language: `/bin/bash`
- Script:
  ```bash
  ~/gene-workspace/gene/example-projects/alfred_app/run.sh "{query}"
  ```

### 3. Connect
```
[Hotkey] → [Script Filter] → [Run Script]
```

## Usage

1. Press hotkey → type command (e.g. `ls -la /tmp`)
2. History items filter as you type
3. Select to run; output goes to clipboard/Large Type
4. Supports quotes, pipes, redirects: `grep "hello world" file.txt | wc -l`

## History

Stored in `~/.gene-commander/history.json`. New commands prepend to top. Existing commands get their count incremented.
