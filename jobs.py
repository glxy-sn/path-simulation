"""
Job manager: jalankan tiap job sebagai SUBPROCESS (worker.py), bukan thread.
Alasan: MPS/torch tidak stabil di thread background -> segfault. Di subprocess
(main thread sendiri) stabil. Progress & hasil dibaca dari file di workdir.
"""
import sys
import uuid
import json
import threading
import subprocess
from pathlib import Path

from config import Config
from models import JobRequest, ProgressResponse

_ENGINE_DIR = Path(__file__).parent


class JobManager:
    def __init__(self):
        self._lock = threading.Lock()
        self._procs = {}   # jid -> subprocess.Popen

    def submit(self, req: JobRequest) -> str:
        jid = uuid.uuid4().hex[:12]
        workdir = Path(Config.WORKDIR) / jid
        workdir.mkdir(parents=True, exist_ok=True)

        job_path = workdir / "job.json"
        job_path.write_text(req.model_dump_json(), encoding="utf-8")
        (workdir / "progress.json").write_text(
            json.dumps({"status": "queued", "stage": "queued", "fraction": 0.0, "error": None}),
            encoding="utf-8")

        proc = subprocess.Popen(
            [sys.executable, str(_ENGINE_DIR / "worker.py"), str(job_path), str(workdir)],
            cwd=str(_ENGINE_DIR),
        )
        with self._lock:
            self._procs[jid] = proc
        return jid

    def progress(self, jid: str):
        workdir = Path(Config.WORKDIR) / jid
        prog = self._read_progress(workdir)
        if prog is None:
            return None

        # Deteksi worker yang mati tanpa menulis done/error (mis. segfault).
        with self._lock:
            proc = self._procs.get(jid)
        if proc is not None and proc.poll() is not None:
            if prog["status"] not in ("done", "error") and proc.returncode != 0:
                prog = {
                    "status": "error",
                    "stage": prog.get("stage", "?"),
                    "fraction": prog.get("fraction", 0.0),
                    # Pengguna aplikasi tidak punya terminal untuk dilihat; keluaran worker
                    # ikut tercatat di backend.log yang ditulis aplikasi.
                    "error": f"Proses analisis berhenti tak terduga (exit {proc.returncode}). Rinciannya ada di backend.log.",
                }

        return ProgressResponse(jobId=jid, status=prog["status"], stage=prog["stage"],
                                fraction=prog["fraction"], error=prog.get("error"))

    def result(self, jid: str):
        res_path = Path(Config.WORKDIR) / jid / "result.json"
        if not res_path.exists():
            return None
        return json.loads(res_path.read_text(encoding="utf-8"))

    def _read_progress(self, workdir: Path):
        p = workdir / "progress.json"
        if not p.exists():
            return None
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            # kemungkinan sedang ditulis; anggap masih jalan
            return {"status": "running", "stage": "?", "fraction": 0.0, "error": None}