# [PROJECT_NAME]

[Brief description of the project.]

## Quick Start

### 1. Clone and enter the project

```bash
git clone <repo-url>
cd [PROJECT_NAME]
```

### 2. Set up Claude Code tools

Run once per machine; safe to re-run.

```bash
bash setup_claude_tools.sh
```

Installs:

| Tool | Role |
|------|------|
| **graphify** | Semantic knowledge graph over code and docs — query structure instead of grepping |
| **caveman** | Output compression, roughly 65% fewer output tokens, plus the cavecrew subagents |
| **RTK** | Shell output compression through a `PreToolUse` hook |
| **superpowers** | Brainstorm → spec → plan → TDD workflow gates |

Also installs Claude Code, Node.js (required by caveman's hooks), and uv, when
they are missing.

The script probes what the machine can do rather than detecting a named
environment, so the same file works on macOS, a RunPod container, a non-root
Linux workstation, and an HPC login node.

| Flag | Effect |
|------|--------|
| `--check` | Print the environment probe table and tool status; change nothing |
| `--prefix PATH` | Install root (default: `$CLAUDE_TOOLS_PREFIX`, then a writable `/workspace`, then `$HOME`) |
| `--extra-dir PATH` | Repeatable; grants Claude access to another directory |
| `--non-interactive` | Never prompt |
| `--skip-all` | Skip every install step; performs only the persistence symlink |
| `--skip-claude`, `--skip-auth`, `--skip-node`, `--skip-plugins`, `--skip-rtk`, `--skip-uv`, `--skip-graphify`, `--skip-perms` | Skip one step |

Start with `bash setup_claude_tools.sh --check` to see what it would target.

#### What it changes on your machine

The script writes outside this repo. Everything it touches is user-level — it
never writes project-scoped Claude config, so permissions stay a decision you
make for your own account rather than something a cloned template grants you.

| Path | What lands there |
|------|------------------|
| `~/.claude/CLAUDE.md` | A tool-routing block — how to use graphify and RTK. Written between `<!-- claude-tools:start -->` and `<!-- claude-tools:end -->` |
| `~/.claude/settings.json` | The RTK `PreToolUse` hook, and any `--extra-dir` paths |
| `~/.claude/hooks/rtk-rewrite.sh` | The RTK hook wrapper |
| `~/.local/bin/` | `rtk`, `uv`, `graphify` (or your `--prefix`) |

To see the routing block it installed:

```bash
sed -n '/claude-tools:start/,/claude-tools:end/p' ~/.claude/CLAUDE.md
```

**Anything you write outside those two markers is yours and is preserved.** Re-runs
replace only the block between them, leaving the rest of the file — your own notes,
other tools' sections, `@` imports — untouched and in their original order. To change
what goes inside the block, edit `routing_block_content()` in `setup_claude_tools.sh`;
editing between the markers by hand is overwritten on the next run.

On a container with an ephemeral home directory, the script keeps Claude's
config on the persistent volume and symlinks `~/.claude` to it. After a restart,
`bash setup_claude_tools.sh --skip-all` restores the link in under a second.

### 3. Create the Python environment

```bash
uv sync                    # creates .venv from pyproject.toml
source .venv/bin/activate  # or: uv run python script.py
```

### 4. Configure paths

`code/utils/config.py` detects `BASE_DIR` automatically. Override the rest with
environment variables when your data lives elsewhere:

- `DATASETS_DIR` — raw data
- `SCRATCH` or `TMPDIR` — intermediate files

### 5. Build the knowledge graph

```bash
graphify .                    # extract code into graphify-out/graph.json
graphify cluster-only .       # cluster and name communities, write GRAPH_REPORT.md
graphify install --project    # register the skill in .claude/skills/
```

Claude then answers structural questions from the graph instead of reading files.
`graphify-out/` is gitignored — it is regenerable from source.

## Working with the toolchain

Four tools, each solving a different problem. Two of them cost you nothing to use —
they work through hooks. The other two you invoke deliberately.

| Tool | The problem | What you get |
|------|-------------|--------------|
| **graphify** | Grep answers "where does this string appear." It cannot answer "what breaks if I change this." | A queryable graph of your code's structure |
| **superpowers** | Agents jump to code before the problem is understood, then declare success without checking. | Workflow gates: design before code, evidence before claims |
| **RTK** | A single `git diff` or test run can flood the context window with output nobody reads. | 60–90% smaller command output, automatically |
| **caveman** | Verbose prose burns output tokens without adding information. | ~65% fewer output tokens, same technical content |

### graphify — ask the graph, don't grep

Build once per repo (step 5 above), then re-extract after significant changes:

```bash
graphify update .             # re-extract, no LLM needed
graphify watch .              # or rebuild automatically as you edit
```

The queries worth knowing:

```bash
graphify query "how does preprocessing feed the model?"   # traverse from a question
graphify affected "load_subject"                          # what breaks if I change this
graphify explain "run_pipeline"                           # plain-language node summary
graphify god-nodes                                        # the architectural hubs
graphify path "load_data" "save_results"                  # how are these connected
```

**Use the graph for structure, grep for text.** "Who calls this function" is a graph
question. "Where does the string `subject_id` appear" is a grep question. Asking the
wrong tool wastes a lot of context.

### superpowers — the workflow, not just skills

The core idea: **separate deciding what to build from building it**, and require
evidence before any success claim. The main path:

```
brainstorming  →  writing-plans  →  subagent-driven-development  →  code review
   (design)        (task list)         (execute + review)
```

- **`/superpowers:brainstorming`** — before any feature. Asks questions one at a
  time, proposes approaches, and will not write code until you approve a design.
  Bounded changes get a short design in chat; new subsystems get a written spec.
- **`/superpowers:writing-plans`** — turns an approved spec into numbered tasks, each
  with exact files, real test code, and a commit. No "TBD", no "add error handling."
- **`/superpowers:subagent-driven-development`** — runs the plan with a fresh agent
  per task and an independent reviewer after each. Catches what a single long session
  stops noticing.
- **`/superpowers:test-driven-development`** — write the failing test, watch it fail,
  then implement. The "watch it fail" step is what proves the test works.
- **`/superpowers:systematic-debugging`** — for any bug, before proposing a fix.
- **`/superpowers:verification-before-completion`** — run the command, read the
  output, then claim success. Not before.

**When to reach for it:** multi-step work where being wrong is expensive. For a
one-line fix it is overhead — say so and skip it.

### RTK — automatic, but check the savings

A `PreToolUse` hook rewrites Bash commands through `rtk` for you. Write commands
normally. To see what it saved:

```bash
rtk gain                      # token savings this session
rtk gain --history            # per-command breakdown
```

Occasionally useful directly: `rtk err <cmd>` (errors only), `rtk test <cmd>`
(failures only), `rtk diff` (changed lines only).

One conflict to know about: don't run RTK alongside a second tool that also
registers a `PreToolUse` hook on `Bash` — they compete to rewrite the same
command. Pick one.

### caveman — output compression

Active by default. Adjust when it gets in the way:

```
/caveman lite | full | ultra | off
/caveman-stats                # tokens and dollars saved
```

It also ships subagents that return compressed findings — `cavecrew-investigator`
to locate code, `cavecrew-reviewer` to review a diff — which keeps the main
conversation smaller on long sessions.

### A session that uses all four

```
1. "Index this project"              → graphify builds the graph
2. /superpowers:brainstorming        → agree on a design before code exists
3. /superpowers:writing-plans        → the design becomes reviewable tasks
4. Execute                           → RTK shrinks command output, caveman shrinks prose
5. /code-review                      → independent check before merge
```

The pattern: **graphify answers what the code is, superpowers governs how work
proceeds, RTK and caveman keep the context window from filling up while it happens.**

## Tests

The tool setup script has its own suite — plain bash, no framework, no network:

```bash
bash tests/test_setup_claude_tools.sh
```

It covers the environment probes, flag parsing, JSON merging, and the marker-block
rewriting that keeps `~/.claude/CLAUDE.md` idempotent across runs.
