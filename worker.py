"""
Worker: jalankan SATU job di proses terpisah (punya main thread sendiri).
Ini menghindari crash MPS/torch yang terjadi kalau ML dijalankan di thread
background server. Dipanggil oleh jobs.py:

    python worker.py <job.json> <workdir>

Menulis progress.json (di-update berkala) dan result.json ke <workdir>.
"""
import os
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import sys
import json
import time
import traceback
from pathlib import Path

try:
    import cv2
    cv2.setNumThreads(0)
except Exception:
    pass

from models import JobRequest
from pipeline.run import run_job


def _atomic_write(path: Path, text: str):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)      # rename atomik -> server tak pernah baca file separuh


def main():
    job_path = Path(sys.argv[1])
    workdir = Path(sys.argv[2])
    workdir.mkdir(parents=True, exist_ok=True)
    prog_path = workdir / "progress.json"
    res_path = workdir / "result.json"

    def write_progress(status, stage, fraction, error=None):
        _atomic_write(prog_path, json.dumps(
            {"status": status, "stage": stage, "fraction": float(fraction), "error": error}))

    write_progress("running", "detection", 0.0)
    last = [0.0]

    def progress(stage, fraction):
        now = time.time()
        if now - last[0] > 0.3 or fraction >= 1.0:      # throttle tulisan
            write_progress("running", stage, fraction)
            last[0] = now

    try:
        req = JobRequest(**json.loads(job_path.read_text(encoding="utf-8")))
        result = run_job(workdir.name, req, progress)
        _atomic_write(res_path, result.model_dump_json())
        write_progress("done", "done", 1.0)
    except Exception as e:
        write_progress("error", "error", 0.0,
                       f"{type(e).__name__}: {e}\n{traceback.format_exc()}")
        sys.exit(1)


if __name__ == "__main__":
    main()