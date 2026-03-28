# [PROJECT_NAME]

[Brief description of the project.]

## Quick Start

### 1. Clone and enter the project

```bash
git clone <repo-url>
cd [PROJECT_NAME]
```

### 2. Set up Claude Code tools (RTK + jCodemunch)

Run once per user account (safe to re-run):

```bash
bash setup_claude_tools.sh
```

This installs:
- **uv** — fast Python package manager (replaces conda/pip for new projects)
- **RTK** — Rust Token Killer, reduces Claude token usage 60-90%
- **jCodemunch-MCP** — fast codebase indexing for Claude Code exploration

Options:
```bash
bash setup_claude_tools.sh --skip-rtk   # skip RTK
bash setup_claude_tools.sh --skip-mcp   # skip jCodemunch
bash setup_claude_tools.sh --skip-uv    # skip uv
```

### 3. Create the Python environment

```bash
# uv (recommended for new projects)
uv sync                    # creates .venv and installs from pyproject.toml
source .venv/bin/activate  # or: uv run python script.py

# conda (legacy)
conda env create -n [ENV_NAME] -f environment.yml
conda activate [ENV_NAME]
```

### 4. Configure paths

Edit `code/utils/config.py` and update:
- `BASE_DIR` — path to this project
- `DATASETS_DIR` — location of raw data
- `SCRATCH_DIR` — scratch space for intermediate files

### 5. Index the project in Claude Code

Open Claude Code in this directory and ask:
> "Index this project"

Claude will call `index_folder` via jCodemunch-MCP. Subsequent code exploration
uses symbol search instead of file reads — much faster and cheaper.

## Project Structure

```
[PROJECT_NAME]/
├── code/
│   ├── analysis/          # Core analysis scripts
│   ├── notebooks/         # Jupyter notebooks
│   ├── plot/              # Plotting scripts
│   ├── stats/             # Statistical analysis (Python/R)
│   ├── submit_scripts/    # HPC job scripts (optional — SLURM/dSQ)
│   │   ├── dsq/           # DSQ shell scripts
│   │   └── joblists/      # Job lists (one command per line)
│   └── utils/
│       └── config.py      # Centralized path configuration
├── datasets/              # Symlinks or metadata for raw data (gitignored)
├── derivatives/           # Analysis outputs (gitignored)
│   ├── results/
│   └── logs/
├── pyproject.toml         # Python dependencies (uv)
├── setup_claude_tools.sh  # One-time environment setup
└── CLAUDE.md              # Instructions for Claude Code
```

## Dependencies

Managed via `uv`. Edit `pyproject.toml` to add packages, then:

```bash
uv add numpy scipy pandas     # add dependencies
uv sync                       # sync environment
uv run python script.py       # run without activating venv
```

## HPC Usage (optional)

If running on an HPC cluster with SLURM and [dSQ](https://github.com/ycrc/dSQ), place job scripts
in `code/submit_scripts/`. Skip this section if running locally or on a different scheduler.

```bash
# Submit a job array
sbatch code/submit_scripts/dsq/dsq_[analysis].sh

# Monitor
dsqa -j [JOB_ID]
squeue -u $USER
```

## Claude Code Tips

- Use `rtk git status`, `rtk git diff`, etc. for compact output
- Use `rtk gain` to see token savings
- Run `/mcp` in Claude Code to verify jCodemunch is connected
- Ask Claude "Find the [function_name] function" — it uses symbol search, not file reads
