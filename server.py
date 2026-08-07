"""
Server sidecar (FastAPI). App Swift memanggilnya di localhost.

Endpoint:
  GET  /health                 -> { status, device }
  POST /jobs                   -> { jobId }              (body = JobRequest)
  GET  /jobs/{id}/progress     -> ProgressResponse       (di-poll oleh layar Proses)
  GET  /jobs/{id}/result       -> JobResult              (saat status == done)
  GET  /artifacts?path=...     -> file                   (opsional; app juga bisa baca file:// langsung)

Jalankan: python server.py   (atau: uvicorn server:app --host 127.0.0.1 --port 8765)
"""
import os
from pathlib import Path
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse, HTMLResponse, Response

from config import Config
from models import JobRequest
from jobs import JobManager

app = FastAPI(title="Foodcourt Engine", version="0.1.0")
manager = JobManager()


@app.get("/health")
def health():
    return {"status": "ok", "device": Config.DEVICE}


@app.post("/jobs")
def create_job(req: JobRequest):
    return {"jobId": manager.submit(req)}


@app.get("/jobs/{jid}/progress")
def get_progress(jid: str):
    p = manager.progress(jid)
    if p is None:
        raise HTTPException(status_code=404, detail="job tidak ditemukan")
    return p


@app.get("/jobs/{jid}/result")
def get_result(jid: str):
    r = manager.result(jid)
    if r is None:
        raise HTTPException(status_code=404, detail="hasil belum siap")
    return r


@app.get("/artifacts")
def get_artifact(path: str = Query(...)):
    # Hanya izinkan file di dalam WORKDIR (cegah path traversal).
    root = str(Config.WORKDIR)
    real = os.path.realpath(path)
    if not real.startswith(root):
        raise HTTPException(status_code=403, detail="di luar workdir")
    if not os.path.exists(real):
        raise HTTPException(status_code=404, detail="file tidak ada")
    return FileResponse(real)


@app.get("/video-info")
def video_info(path: str = Query(...)):
    """Durasi + resolusi + fps video (untuk set max slider)."""
    import cv2
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise HTTPException(status_code=404, detail="video tidak bisa dibuka")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    frames = cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()
    return {"durationSec": (frames / fps if fps else 0), "width": w, "height": h, "fps": fps}


@app.get("/thumbnail")
def thumbnail(path: str = Query(...), t: float = 0.0):
    """Frame JPEG di detik t (untuk preview slider)."""
    import cv2
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise HTTPException(status_code=404, detail="video tidak bisa dibuka")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    cap.set(cv2.CAP_PROP_POS_FRAMES, int(max(0, t) * fps))
    ok, frame = cap.read()
    cap.release()
    if not ok:
        raise HTTPException(status_code=404, detail="frame tidak ada")
    h, w = frame.shape[:2]
    scale = 360.0 / max(w, 1)
    frame = cv2.resize(frame, (int(w * scale), int(h * scale)))
    ok, buf = cv2.imencode(".jpg", frame)
    return Response(content=buf.tobytes(), media_type="image/jpeg")


@app.get("/", response_class=HTMLResponse)
def index():
    """Halaman tes: upload path video, slider trim, run job, lihat hasil."""
    page = Path(__file__).parent / "web" / "test.html"
    if not page.exists():
        return "<h3>web/test.html tidak ditemukan</h3>"
    return page.read_text(encoding="utf-8")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=Config.HOST, port=Config.PORT)