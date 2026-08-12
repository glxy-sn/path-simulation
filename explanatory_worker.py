"""Build one explanatory package in a separate process."""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from config import Config
from explanatory_analysis.pipeline import AnalysisConfig, run_analysis


def atomic(path: Path, value: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def main() -> None:
    job_id = sys.argv[1]
    directory = Path(Config.WORKDIR) / job_id
    status_path = directory / "explanatory-status.json"
    try:
        while True:
            context = json.loads((directory / "analysis-context.json").read_text(encoding="utf-8"))
            revision = int(context.get("contextRevision") or 1)
            atomic(status_path, {
                "jobId": job_id, "state": "building", "progress": 0.2,
                "error": None, "buildingRevision": revision,
            })
            result = run_analysis(AnalysisConfig(Path(__file__).resolve().parent, Path(Config.WORKDIR), Path(Config.WORKDIR), job_id))
            current_context = json.loads((directory / "analysis-context.json").read_text(encoding="utf-8"))
            current_revision = int(current_context.get("contextRevision") or 1)
            if current_revision != revision:
                # Tetap dalam satu worker: package baru saja menjadi stale saat
                # dibangun, jadi ulangi untuk revision terbaru tanpa proses kedua.
                continue
            atomic(status_path, {
                "jobId": job_id,
                "state": "ready",
                "progress": 1.0,
                "error": None,
                "contextRevision": current_revision,
                "packagePath": str(result.output_dir),
                "updatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            })
            break
    except Exception as error:
        atomic(status_path, {"jobId": job_id, "state": "error", "progress": 0.0, "error": f"{type(error).__name__}: {error}"})
        raise


if __name__ == "__main__":
    main()
