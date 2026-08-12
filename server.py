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
from fastapi import FastAPI, HTTPException, Query, Response as FastAPIResponse
from fastapi.responses import FileResponse, HTMLResponse, Response

from config import Config
from models import JobRequest, CalibrationPreviewRequest, CalibrationReprojectRequest
from jobs import JobManager
from pipeline.preview import CalibrationPreviewManager
from explanatory_service import (
    AnalysisContextUpdate,
    ChatMessageCreate,
    ChatSessionCreate,
    ChatSessionManager,
    ChatSessionPatch,
    ExplanatoryManager,
)

app = FastAPI(title="Foodcourt Engine", version="0.1.0")
manager = JobManager()
preview_manager = CalibrationPreviewManager()
explanatory_manager = ExplanatoryManager()
chat_manager = ChatSessionManager(explanatory_manager)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "device": Config.DEVICE,
        "explanatory": {"available": True, "chatModel": "qwen3:14b", "embeddingModel": "qwen3-embedding:0.6b"},
    }


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
    try:
        explanatory_manager.build(jid)
    except RuntimeError:
        pass
    return r


@app.post("/jobs/{jid}/explanatory/build")
def build_explanatory(jid: str):
    try:
        return explanatory_manager.build(jid)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except (ValueError, RuntimeError) as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@app.get("/jobs/{jid}/explanatory/status")
def explanatory_status(jid: str):
    try:
        return explanatory_manager.status(jid)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.put("/jobs/{jid}/analysis-context")
def update_analysis_context(jid: str, update: AnalysisContextUpdate):
    try:
        return explanatory_manager.update_context(jid, update)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except (ValueError, RuntimeError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.get("/jobs/{jid}/chat-sessions")
def list_chat_sessions(jid: str):
    try:
        return {"sessions": chat_manager.list(jid)}
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.post("/jobs/{jid}/chat-sessions")
def create_chat_session(jid: str, request: ChatSessionCreate):
    try:
        return chat_manager.create(jid, request)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.get("/jobs/{jid}/chat-sessions/{session_id}")
def get_chat_session(jid: str, session_id: str):
    try:
        return chat_manager.get(jid, session_id)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.patch("/jobs/{jid}/chat-sessions/{session_id}")
def rename_chat_session(jid: str, session_id: str, request: ChatSessionPatch):
    try:
        return chat_manager.rename(jid, session_id, request)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.delete("/jobs/{jid}/chat-sessions/{session_id}", status_code=204)
def delete_chat_session(jid: str, session_id: str):
    try:
        chat_manager.delete(jid, session_id)
        return FastAPIResponse(status_code=204)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.post("/jobs/{jid}/chat-sessions/{session_id}/messages")
def send_chat_message(jid: str, session_id: str, request: ChatMessageCreate):
    try:
        return chat_manager.ask(jid, session_id, request)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except (ConnectionError, TimeoutError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except RuntimeError as exc:
        detail = str(exc)
        status = 409 if "belum siap" in detail else 503
        raise HTTPException(status_code=status, detail=detail) from exc


@app.get("/jobs/{jid}/chat-sessions/{session_id}/runs/{run_id}/artifacts/{filename}")
def get_chat_artifact(jid: str, session_id: str, run_id: str, filename: str):
    try:
        session_directory = chat_manager._session_dir(jid, session_id)
        chat_manager.get(jid, session_id)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    allowed = {"floorplan_overlay.png"}
    safe_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
    if not run_id or any(char not in safe_chars for char in run_id) or filename not in allowed:
        raise HTTPException(status_code=404, detail="artefak tidak ditemukan")
    root = Path(Config.WORKDIR).resolve()
    artifact = (session_directory / "runs" / run_id / filename).resolve()
    if not artifact.is_relative_to(root) or not artifact.is_file():
        raise HTTPException(status_code=404, detail="artefak tidak ditemukan")
    return FileResponse(artifact)


@app.get("/artifacts")
def get_artifact(path: str = Query(...)):
    # Hanya izinkan file di dalam WORKDIR (cegah path traversal).
    root = Path(Config.WORKDIR).resolve()
    real = Path(path).expanduser().resolve()
    if not real.is_relative_to(root):
        raise HTTPException(status_code=403, detail="di luar workdir")
    if not real.exists():
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


@app.post("/calibration-preview/sample")
async def calibration_preview_sample(req: CalibrationPreviewRequest):
    """Run one short YOLO/OSNet burst and cache descriptors in memory."""
    try:
        return preview_manager.sample(req)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.post("/calibration-preview/reproject")
async def calibration_preview_reproject(req: CalibrationReprojectRequest):
    """Re-use cached detections/descriptors after homography edits."""
    try:
        return preview_manager.reproject(req)
    except KeyError as exc:
        raise HTTPException(status_code=410, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


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
