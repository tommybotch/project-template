"""
Centralized path configuration for [PROJECT_NAME].
BASE_DIR is auto-detected from this file's location — no edits needed for that.
Update DATASETS_DIR and SCRATCH_DIR if your data lives elsewhere.
"""

import os
import sys
from pathlib import Path

# --- Core paths ---
# Resolved from this file's location: code/utils/config.py -> project root
BASE_DIR = Path(__file__).resolve().parents[2]

# Raw data — defaults to datasets/ inside the project; override if data lives elsewhere
DATASETS_DIR = Path(os.environ.get("DATASETS_DIR", str(BASE_DIR / "datasets")))

# Scratch/temp space — uses $SCRATCH (common on HPC) or $TMPDIR, then falls back to .scratch/
SCRATCH_DIR = Path(os.environ.get("SCRATCH", os.environ.get("TMPDIR", str(BASE_DIR / ".scratch"))))

# --- Derived paths (don't edit) ---
CODE_DIR = BASE_DIR / "code"
DERIVATIVES_DIR = BASE_DIR / "derivatives"
RESULTS_DIR = DERIVATIVES_DIR / "results"
LOGS_DIR = DERIVATIVES_DIR / "logs"

# --- HPC/dSQ only: environment activation string for SLURM job scripts ---
# Only needed when using dSQ on an HPC cluster. Import in your dsq shell scripts.
# Works with both uv .venv and conda environments.
DSQ_MODULES = f"source {sys.prefix}/bin/activate"

# Ensure output directories exist
for _d in [RESULTS_DIR, LOGS_DIR, SCRATCH_DIR]:
    os.makedirs(_d, exist_ok=True)
