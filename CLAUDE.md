# [PROJECT_NAME]

## Coding Guidelines

Behavioral guidelines that reduce common LLM coding mistakes. Adapted from
[andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills)
(MIT), derived from Andrej Karpathy's observations on LLM coding pitfalls.

**Tradeoff:** These bias toward caution over speed. For trivial tasks, use judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:
- Remove imports, variables, and functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: every changed line should trace directly to the request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it
work") require constant clarification.

## Tooling

Tool conventions — graphify for code exploration, RTK for shell commands — are not
repeated here. They live once in `~/.claude/CLAUDE.md`, between the markers
`<!-- claude-tools:start -->` and `<!-- claude-tools:end -->`, written by
`setup_claude_tools.sh`. To read them:

```bash
sed -n '/claude-tools:start/,/claude-tools:end/p' ~/.claude/CLAUDE.md
```

To change them, edit `routing_block_content()` in `setup_claude_tools.sh` and re-run
it — hand edits between the markers are overwritten. Anything outside the markers is
preserved across runs.

## Project Overview

[Brief description of the project's scientific goals and methods.]

## Environment

Activate the project environment before running any script:

```bash
source .venv/bin/activate
# or: uv run python script.py
```

## Tests

```bash
bash tests/test_setup_claude_tools.sh   # tool setup script; plain bash, no framework
pytest                                  # project tests, once you add them
```

## Project Structure

```
[PROJECT_NAME]/
├── code/
│   ├── analysis/          # Core analysis scripts
│   ├── notebooks/         # Jupyter notebooks for exploration/visualization
│   ├── plot/              # Plotting utilities
│   ├── stats/             # Statistical analysis (Python/R)
│   ├── submit_scripts/    # HPC job submission (optional — SLURM/dSQ)
│   │   ├── dsq/           # dSQ shell scripts
│   │   └── joblists/      # Job list text files
│   └── utils/             # Shared utilities
│       └── config.py      # Centralized path configuration
├── datasets/              # Symlinks or metadata for raw data
├── derivatives/
│   ├── results/           # Analysis outputs
│   └── logs/              # Job logs
├── docs/                  # Design docs and specs
├── tests/                 # Test suite
├── setup_claude_tools.sh  # One-time Claude Code tool setup
├── pyproject.toml         # Dependencies and Python version
└── README.md
```

## Path Configuration

All paths are centralized in `code/utils/config.py`:

- `BASE_DIR` — project root, auto-detected from the file's location
- `DATASETS_DIR` — raw data; override with the `DATASETS_DIR` environment variable
- `SCRATCH_DIR` — intermediate files; uses `$SCRATCH`, then `$TMPDIR`, then `.scratch/`

## HPC Usage (optional)

For SLURM clusters with dSQ. Skip when running locally or under another scheduler.

```bash
sbatch code/submit_scripts/dsq/dsq_[analysis].sh   # submit a dSQ job array
dsqa -j [JOB_ID]                                   # check status
```
