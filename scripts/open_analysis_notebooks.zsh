#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
BACKEND_ROOT=${SCRIPT_DIR:h}
PROJECT_ROOT=${BACKEND_ROOT:h:h}
HANDOVER_NOTEBOOKS=${PROJECT_ROOT}/project_handover/notebooks
exec "$BACKEND_ROOT/.venv-analysis/bin/jupyter" lab "$HANDOVER_NOTEBOOKS/trajectory_explanatory_analysis.ipynb" "$HANDOVER_NOTEBOOKS/local_rag_qwen3_analysis.ipynb"
