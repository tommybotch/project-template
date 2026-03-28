# [PROJECT_NAME]

## Environment

Always activate the project environment before running any scripts:

```bash
# uv-based (preferred for new projects)
source .venv/bin/activate
# or: uv run python script.py

# conda-based (legacy)
conda activate [ENV_NAME]
```

## RTK Usage

Always prefix shell commands with `rtk` to reduce token usage by 60-90%:

```bash
rtk git status          # compact git status
rtk git log             # compact log
rtk ls <path>           # tree format
rtk grep <pattern>      # grouped search results
```

See the RTK section below for the full command reference.

## Code Exploration Policy

Always use jCodemunch-MCP tools for code exploration — they are faster and use fewer tokens.
If jCodemunch-MCP is not connected, **stop and diagnose** — do not fall back to Read/Grep/Glob.
Check `/mcp` in Claude Code; if disconnected, re-run `setup_claude_tools.sh` to re-register.

- Before reading a file: use `get_file_outline` or `get_file_content`
- Before searching: use `search_symbols` or `search_text`
- Before exploring structure: use `get_file_tree` or `get_repo_outline`
- Call `resolve_repo` with the current directory first; if not indexed, call `index_folder`.

## Project Overview

[Brief description of the project's scientific goals and methods.]

## Project Structure

```
[PROJECT_NAME]/
├── code/
│   ├── analysis/          # Core analysis scripts
│   ├── notebooks/         # Jupyter notebooks for exploration/visualization
│   ├── plot/              # Plotting utilities
│   ├── stats/             # Statistical analysis (Python/R)
│   ├── submit_scripts/    # HPC job submission scripts (optional — SLURM/dSQ)
│   │   ├── dsq/           # DSQ shell scripts
│   │   └── joblists/      # Job list text files
│   └── utils/             # Shared utility functions
│       └── config.py      # Centralized path configuration
├── datasets/              # Symlinks or metadata for raw data
├── derivatives/
│   ├── results/           # Analysis outputs
│   └── logs/              # Job logs
└── README.md
```

## Path Configuration

All paths are centralized in `code/utils/config.py`. Update before running any scripts:

- `BASE_DIR`: project root
- `DATASETS_DIR`: location of raw data
- `SCRATCH_DIR`: temporary/intermediate files

## HPC Usage (optional)

If running on an HPC cluster with SLURM and dSQ (Dead Simple Queue), use scripts in
`code/submit_scripts/`. Skip this section if running locally or on a different scheduler.

```bash
# Submit a dSQ job array
sbatch code/submit_scripts/dsq/dsq_[analysis].sh

# Check job status
dsqa -j [JOB_ID]
```

<!-- rtk-instructions v2 -->
# RTK (Rust Token Killer) - Token-Optimized Commands

## Golden Rule

**Always prefix commands with `rtk`**. If RTK has a dedicated filter, it uses it. If not, it passes through unchanged. This means RTK is always safe to use.

**Important**: Even in command chains with `&&`, use `rtk`:
```bash
# ❌ Wrong
git add . && git commit -m "msg" && git push

# ✅ Correct
rtk git add . && rtk git commit -m "msg" && rtk git push
```

## RTK Commands by Workflow

### Git (59-80% savings)
```bash
rtk git status          # Compact status
rtk git log             # Compact log
rtk git diff            # Compact diff (80%)
rtk git add             # Ultra-compact confirmations
rtk git commit          # Ultra-compact confirmations
rtk git push / pull     # Ultra-compact confirmations
```

### Files & Search (60-75% savings)
```bash
rtk ls <path>           # Tree format, compact (65%)
rtk grep <pattern>      # Search grouped by file (75%)
rtk find <pattern>      # Find grouped by directory (70%)
```

### Analysis & Debug (70-90% savings)
```bash
rtk err <cmd>           # Filter errors only
rtk log <file>          # Deduplicated logs with counts
rtk summary <cmd>       # Smart summary of command output
```

### Meta Commands
```bash
rtk gain                # View token savings statistics
rtk gain --history      # View command history with savings
```

Overall average: **60-90% token reduction** on common development operations.
<!-- /rtk-instructions -->
