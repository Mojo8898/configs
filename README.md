# dotfiles / configs

Configuration files for pi, tmux, and zsh.

---

## Structure

```
configs/
├── pi/
│   ├── settings.json              # Model/provider selection
│   ├── prompts/
│   │   └── verify.md              # Verification mode prompt template
│   └── skills/
│       └── orchestrator/
│           └── SKILL.md           # Orchestrator skill
├── tmux/
│   ├── tmux.conf                  # Entry point (sources config/)
│   └── config/
│       ├── options.conf           # Server/session/window options
│       ├── keybindings.conf       # Key bindings and copy mode
│       └── theme.conf             # Status bar and colour theme
└── zsh/
    └── .zshrc                     # Interactive shell config (secrets blanked)
```

---

## Prerequisites

```bash
# pi
npm install -g @mariozechner/pi-coding-agent

# tmux plugin manager
git clone https://github.com/tmux-plugins/tpm ~/.config/tmux/plugins/tpm

# zsh plugins (Kali/Debian)
apt install zsh-syntax-highlighting zsh-autosuggestions
```

---

## Installation

### pi

```bash
mkdir -p ~/.pi/agent/prompts ~/.pi/agent/skills/orchestrator

cp pi/settings.json        ~/.pi/agent/settings.json
cp pi/prompts/verify.md    ~/.pi/agent/prompts/verify.md
cp pi/skills/orchestrator/SKILL.md ~/.pi/agent/skills/orchestrator/SKILL.md
```

Then add your API key — pi will prompt on first launch, or set it manually:

```bash
# pi stores credentials in ~/.pi/agent/auth.json
pi  # follow the first-run prompt
```

### tmux

```bash
mkdir -p ~/.config/tmux/config

cp tmux/tmux.conf        ~/.config/tmux/tmux.conf
cp tmux/config/options.conf     ~/.config/tmux/config/options.conf
cp tmux/config/keybindings.conf ~/.config/tmux/config/keybindings.conf
cp tmux/config/theme.conf       ~/.config/tmux/config/theme.conf
```

Install plugins (inside a tmux session):

```
prefix + I
```

### zsh

```bash
cp zsh/.zshrc ~/.zshrc
```

Then fill in your secrets at the bottom of `~/.zshrc`:

```bash
export HTB_TOKEN=""          # https://app.hackthebox.com/profile/settings
export ANTHROPIC_API_KEY=""  # https://console.anthropic.com/settings/keys
export BH_TOKEN_ID=""        # BloodHound CE → Administration → API Tokens
export BH_TOKEN_KEY=""       # BloodHound CE → Administration → API Tokens
```

Reload:

```bash
source ~/.zshrc
```

---

## Usage Guide

This setup uses **pi** as an AI coding agent with an orchestrator workflow. The
idea is a two-role split: you talk to the orchestrator (a high-thinking pi
session), which plans, delegates implementation to a separate agent, then
independently verifies the result before asking you to approve.

### Key Concepts

| Concept | What it is |
|---|---|
| **Orchestrator** | The pi session you talk to. Plans features, creates backlog tasks, dispatches the agent, verifies results. Never writes code itself. |
| **Dispatched agent** | A headless pi instance spawned by the orchestrator to do the actual implementation. Runs at medium thinking. |
| **Backlog task** | A structured markdown file tracking a unit of work — description, acceptance criteria, implementation notes, final summary. Managed via the `backlog` CLI. |
| **ARCHITECTURE.md** | A living document in the project root that gives the orchestrator instant context at the start of every session without re-reading the whole codebase. |
| **verify.md prompt** | A custom prompt template that automatically triggers Verification Mode when the orchestrator receives agent output. |

---

### Starting a Session

Navigate to your project directory and launch pi:

```bash
cd /your/project
pi
```

Then load the orchestrator skill:

```
/skill:orchestrator
```

The orchestrator immediately reads `ARCHITECTURE.md`, lists open backlog tasks,
and shows recent git history. It then greets you and waits for instructions.

---

### Typical Workflow

#### 1. Describe what you want

Just tell the orchestrator in plain language:

```
I want to add rate limiting to the API endpoints
```

The orchestrator will:
- Read relevant source files to understand the current state
- Propose an approach with tradeoffs
- Ask clarifying questions or push back if there are problems
- Iterate with you until the approach is agreed

You do not need to specify implementation details — that's the orchestrator's job.

#### 2. Approve the plan

The orchestrator presents its approach. You either approve, refine, or redirect:

```
Looks good, go ahead
```

```
Actually, use a sliding window instead of token bucket
```

Only once you explicitly approve does anything get written.

#### 3. Orchestrator creates a backlog task

The orchestrator creates a structured task capturing the **why** (description)
and **what** (acceptance criteria):

```
backlog task create "Add rate limiting to API endpoints" \
  -d "Prevent abuse by limiting requests per IP" \
  --ac "Requests exceeding limit return HTTP 429" \
  --ac "Limit is configurable via environment variable" \
  --ac "uv run pytest passes" \
  --ac "Changes committed referencing the task ID"
```

#### 4. Agent is dispatched

The orchestrator spawns a headless pi instance to do the implementation:

```
pi --print --no-session --model claude-sonnet-4-6 --thinking medium \
  "Work on TASK-5 only. Read the task first with: backlog task 5 --plain"
```

This runs non-interactively and streams all output back to the orchestrator.
You watch it happen in real time. No input is required from you.

#### 5. Orchestrator verifies

Once the agent finishes, the orchestrator independently checks — **not** based
on what the agent claims it did, but on evidence:

- `backlog task 5 --plain` — are all ACs checked off?
- `git diff HEAD~1` — does the diff match the task scope? Any unexpected files?
- `uv run pytest` — do all tests pass?

It reports findings with specific file/line references and asks:

```
✅ All 4 ACs checked. Diff touches only src/api/middleware.py and tests/test_rate_limit.py.
Tests pass (147/147). Commit exists: abc1234.

Agree / disagree / needs changes?
```

#### 6. You decide

- **Agree** → orchestrator updates `ARCHITECTURE.md` if structure changed, asks what's next
- **Needs changes** → orchestrator identifies the gap, patches the task, re-dispatches
- **Disagree** → orchestrator creates a new task for the corrective work

---

### Ad-hoc Changes (No Dispatch)

Not everything needs a backlog task and agent dispatch. For small, well-understood
fixes the orchestrator handles it directly:

```
# Good examples of ad-hoc:
"Fix the typo in the error message in utils/parser.py"
"The test on line 42 is asserting the wrong index, update it"
"Commit what we have and push"
"Rebase on main"
```

The rule of thumb: if the solution is already obvious from the diagnosis and
touches one file or block, do it directly. If it requires exploration, touches
multiple files, or has real decision points, dispatch.

Either way, tests run before any commit.

---

### Backlog Commands Reference

```bash
backlog task list --plain              # See all tasks and their status
backlog task 5 --plain                 # Read a specific task in full
backlog task create "Title" --ac "..." # Create a new task
backlog board                          # Kanban board in the terminal
backlog search "auth" --plain          # Fuzzy search across tasks
```

---

### tmux Layout

The workflow naturally fits a two-pane tmux layout:

```
┌─────────────────────┬─────────────────────┐
│                     │                     │
│   pi (orchestrator) │   editor / shell    │
│                     │                     │
│   You talk here.    │   Watch diffs,      │
│   Agent output      │   run tests,        │
│   streams here.     │   browse code.      │
│                     │                     │
└─────────────────────┴─────────────────────┘
```

Useful keybindings from the tmux config:

| Key | Action |
|---|---|
| `Shift+←` / `Shift+→` | Switch windows |
| `prefix + j` | Set working directory to current pane path |
| `prefix + J` | Sync all panes to current pane path |
| `prefix + U` | Open aliasr send panel |

---

## Notes

- The tmux config uses `tmux-mode-indicator` and `tmux-sensible` via TPM — both
  are installed automatically by `prefix + I` after copying the config.
- The zsh config assumes Kali/Debian paths for syntax highlighting and
  autosuggestions (`/usr/share/zsh-*/`). On other distros install via package
  manager and adjust the `source` paths if needed.
- pi session history lives in `~/.pi/agent/sessions/` — machine-specific, not
  included here.
