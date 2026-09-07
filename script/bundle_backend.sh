#!/bin/bash
# Run by Xcode before signing, for both Debug and Release builds.
set -euo pipefail
BACKEND_SOURCE="${SRCROOT}/../be/path-simulation"
BACKEND_DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/backend"
PRIVACY_MODEL="deeplabv3_mobilenet_v3_large-fc3c493d.pth"
[[ -f "$BACKEND_SOURCE/server.py" ]] || { echo "error: Backend missing: $BACKEND_SOURCE"; exit 1; }
[[ -f "$BACKEND_SOURCE/models/$PRIVACY_MODEL" ]] || { echo "error: Privacy model missing: $BACKEND_SOURCE/models/$PRIVACY_MODEL"; exit 1; }
bash "$SRCROOT/script/stop_backend_for_build.sh"
mkdir -p "$BACKEND_DEST"
# Synchronize only runtime code and the render privacy model. Deleted source
# modules are removed from the generated bundle as well.
/usr/bin/rsync -a --delete --delete-excluded \
  --exclude '.*' --exclude '.git/' --exclude '.venv*/' --exclude '__pycache__/' \
  --exclude 'tests/' --exclude 'notebooks/' --exclude 'llm_evaluation/' \
  --exclude 'scripts/' --exclude 'hasil*/' \
  --include '*/' --include '*.py' --include 'requirements*.txt' \
  --include "$PRIVACY_MODEL" --exclude '*' \
  "$BACKEND_SOURCE/" "$BACKEND_DEST/"
echo "Bundled latest backend and privacy model from $BACKEND_SOURCE"
