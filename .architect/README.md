# `.architect/` — coordination layer

This directory is how **architect** (running on Vlad's local machine) and the in-pod actor (default: `pod-shell` SSH sub-agent; optional: in-pod Claude Code) coordinate. The repo on `voxelo/main` is the message bus — nothing else.

Pattern: `runpod-persistent-gpu-pod` (status: `tested`). This is the **second** instance after Lyra-2, and the **first** to use the bypass-conda (uv venv) variant.

## Files

| File | Owner | Purpose |
|---|---|---|
| `task.md` | architect | current cycle goal — written at cycle open |
| `handoff.md` | in-pod actor | current cycle status — written at cycle close |
| `log/<date>-cycle-<N>.md` | in-pod actor | append-only event log per cycle |
| `RECIPE.md` | architect (final) | locked, reproducible recipe — written when verification all passes |
| `pod-claude/CLAUDE.md` | architect | pod-Claude's persona (only used in optional autonomous mode) |
| `pod-claude/CONTINUITY.md` | architect | what pod-Claude reads on startup (autonomous mode) |
| `pod-claude/settings.local.template.json` | architect | pod-Claude's permission template (autonomous mode) |

## How a cycle runs (default — pod-shell SSH sub-agent)

1. **Architect writes `task.md`** with goal + verification + scope, commits, pushes.
2. **Architect spawns the `pod-shell` sub-agent**, hands over SSH details + cycle goal.
3. **`pod-shell` ensures the tmux session exists**, pulls the repo on the pod, reads `.architect/task.md`, drives commands via `tmux send-keys`, captures via `tmux capture-pane`, appends to `log/<date>-cycle-<N>.md` continuously.
4. **`pod-shell` writes `handoff.md`** at close, commits + pushes from inside the pod.
5. **Architect pulls**, reads handoff, decides: queue cycle N+1 or lock the recipe.

The full contract is in architect's local memory at `Architect/memory/cycle_protocol.md`.

## Optional autonomous mode (pod-Claude)

For cycles Vlad's laptop won't be online to drive, an in-pod Claude Code can be installed via `scripts/install-pod-claude.sh`. It reads `pod-claude/CONTINUITY.md` on startup. Identical protocol from there. Not the default.

## Rules

- Architect doesn't edit code in this repo. Only `.architect/`.
- The in-pod actor doesn't edit `task.md`. Only `handoff.md` and `log/`.
- All work on `voxelo/main`. `main` tracks upstream, fast-forward only.
- Both sides push, never force-push.
- One cycle at a time. No concurrent writers.
