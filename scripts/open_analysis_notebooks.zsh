#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
BACKEND_ROOT=${SCRIPT_DIR:h}
exec "$BACKEND_ROOT/.venv-analysis/bin/jupyter" lab "$BACKEND_ROOT/notebooks/01_trajectory_explanatory_analysis.ipynb" "$BACKEND_ROOT/notebooks/02_local_llm_retrieval.ipynb"
