# GeneClaw Hot-Swap Self-Upgrade (Proposal)

## Overview

GeneClaw can modify its own source code and hot-swap to a new instance with **bounded downtime** (during PAUSED window). The old instance stays alive as a fallback. If the new code fails to start, the old instance resumes automatically.

This revision captures decisions:
- Bounded downtime (not zero downtime)
- No split-brain lease in v1; PAUSED mode blocks old instance processing
- Old instance termination uses shell process kill (no `/shutdown` endpoint)
- Upgrade state is checkpointed to a temp branch/worktree
- `self_upgrade` requires explicit confirmation

## Architecture

```
┌──────────────────────────────────────────────────┐
│ Agent decides to self-modify                     │
│ 1. Writes code changes via write_file/edit_file  │
│ 2. Requests human approval                       │
│ 3. Calls self_upgrade(confirm=true)              │
└──────────────────┬───────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────┐
│ Upgrade checkpoint                               │
│ - Save changes on temp branch                    │
│ - Create temp worktree for new process           │
└──────────────────┬───────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────┐
│ Old instance enters PAUSED mode                  │
│ - HTTP returns 503 except /health                │
│ - Agent/scheduler processing paused              │
│ - Resume timeout starts (default 2 min)          │
└──────────────────┬───────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────┐
│ Spawn new instance (port + 1) from worktree      │
└──────────────────┬───────────────────────────────┘
                   ▼
            ┌──────┴──────┐
            │ Health poll │
            │ (up to 30s) │
            └──────┬──────┘
           ┌───────┴────────┐
           ▼                ▼
    ┌─────────────┐  ┌────────────┐
    │   Healthy   │  │   Failed   │
    └──────┬──────┘  └──────┬─────┘
           ▼                ▼
  Kill old process      Kill new process
  by old port (shell)   Old process will auto-resume
                        Keep temp branch for review
```

## Components

### 1. Paused Mode (`main.gene`, `agent.gene`, `scheduler.gene`)

When `PAUSED` is true:
- Router allows only `/health`
- All other HTTP endpoints return `503 {"status":"paused","message":"Upgrading"}`
- `run_agent` returns immediately (no LLM/tool execution)
- Scheduler loop skips dispatching jobs

This is the v1 split-brain prevention model: old instance keeps process liveness, but does no work.

A background timer checks every 5 seconds. If `PAUSED` lasts longer than `PAUSE_TIMEOUT_MS` (default 120000), old instance resumes.

```gene
(var PAUSED false)
(var PAUSED_AT nil)
(var PAUSE_TIMEOUT_MS 120000)

(fn check_pause_timeout []
  (if (PAUSED && PAUSED_AT)
    (if ((gene/now/.call/.to_i - PAUSED_AT) > PAUSE_TIMEOUT_MS)
      (log .warn "Pause timeout, resuming old instance")
      (PAUSED = false)
      (PAUSED_AT = nil)
    )
  )
)
```

### 2. Self-Upgrade Tool (`tools/self_upgrade.gene`)

Registered as `self_upgrade` in the tool registry.

Steps:
1. Validate confirmation (`confirm == true`) and reason
2. Save current modified state to temp git branch
3. Create temp git worktree from that branch
4. Pause old instance (`PAUSED = true`, set timer)
5. Launch new instance on `PORT + 1` from temp worktree
6. Poll `/health` on new instance (2s x 15 attempts)
7. Success: kill old process by port via shell
8. Failure: kill new process, clear pause, old resumes

```gene
(register_tool "self_upgrade"
  "Apply code changes and hot-swap to new instance"
  {^type "object"
   ^required ["reason" "confirm"]
   ^properties {
     ^reason  {^type "string" ^description "Why this upgrade"}
     ^confirm {^type "boolean" ^description "Must be true to run upgrade"}
   }}
  (fn [args]
    (if_not args/confirm
      (return {^ok false ^error "confirmation required: pass confirm=true"})
    )

    (var old_port PORT)
    (var new_port (PORT + 1))
    (var ts gene/now/.call/.to_i)
    (var current_branch (system/shell "git branch --show-current")/output/.trim)
    (var upgrade_branch #"geneclaw-upgrade-#{ts}")
    (var upgrade_dir #"/tmp/geneclaw-upgrade-#{ts}")

    # Checkpoint modified state on temp branch/worktree
    (system/shell #"git checkout -b #{upgrade_branch}")
    (system/shell "git add -A")
    (system/shell #"git commit -m 'self_upgrade checkpoint #{ts}'")
    (system/shell #"git checkout #{current_branch}")
    (system/shell #"git worktree add #{upgrade_dir} #{upgrade_branch}")

    # Pause old instance
    (PAUSED = true)
    (PAUSED_AT gene/now/.call/.to_i)

    # Launch new instance from temp worktree
    (system/shell #"cd #{upgrade_dir} && PORT=#{new_port} gene run src/main.gene > /tmp/geneclaw-upgrade-#{ts}.log 2>&1 &")

    # Poll for health
    (var healthy false)
    (var attempts 0)
    (loop
      (if (attempts >= 15) (break))
      (attempts += 1)
      (gene/sleep 2000)
      (try
        (var resp (genex/http/http_get #"http://localhost:#{new_port}/health"))
        (if (resp/status == 200)
          (healthy = true)
          (break)
        )
      catch * nil)
    )

    (if healthy
      # Terminate old process by port (no shutdown endpoint)
      (system/shell #"pid=$(lsof -ti tcp:#{old_port} | head -n1); if [ -n \"$pid\" ]; then kill -TERM $pid; sleep 2; kill -KILL $pid 2>/dev/null || true; fi")
      {^ok true ^new_port new_port ^upgrade_branch upgrade_branch}
    else
      (system/shell #"pid=$(lsof -ti tcp:#{new_port} | head -n1); if [ -n \"$pid\" ]; then kill -TERM $pid; fi")
      (PAUSED = false)
      (PAUSED_AT = nil)
      {^ok false ^error "new instance failed, resumed old" ^upgrade_branch upgrade_branch}
    )
  ))
```

### 3. Human Confirmation Gate

`self_upgrade` should only be exposed behind a human approval step in the chat workflow:
- Agent proposes changes and reason
- Human confirms
- Agent executes `self_upgrade` with `confirm=true`

This is required for v1.

## Safety Guarantees (v1)

| Risk | Mitigation |
|---|---|
| Upgrade triggered accidentally | `self_upgrade` requires explicit `confirm=true` and human approval |
| Split brain duplicate work | Old instance in PAUSED mode blocks agent + scheduler + normal HTTP paths |
| New instance crashes on startup | Health poll timeout, then old instance resumes |
| Local state loss during rollback | Changes saved on temp upgrade branch/worktree |
| Wrong process kill | Kill by bound port with TERM then KILL fallback |

## Usage Flow

1. Agent edits files (`write_file`, etc.)
2. Agent summarizes proposed upgrade and asks for confirmation
3. Human approves
4. Agent calls `self_upgrade` with `{^reason "..." ^confirm true}`
5. Old instance pauses, new instance boots from temp worktree, health is checked
6. If healthy: old process is killed by shell
7. If failed: new process is killed, old instance resumes

## Configuration

| Variable | Default | Description |
|---|---|---|
| `PAUSE_TIMEOUT_MS` | `120000` | How long old instance waits before resuming (ms) |
| `PORT` | `4090` | Main HTTP server port |
| `UPGRADE_HEALTH_ATTEMPTS` | `15` | New instance health attempts |
| `UPGRADE_HEALTH_INTERVAL_MS` | `2000` | Delay between health attempts |

## Deferred for v1

- Extended readiness checks beyond `/health` (Slack socket, scheduler, dependencies)
- Automatic merge/cherry-pick from temp upgrade branch into working branch
- Session migration across old/new processes
