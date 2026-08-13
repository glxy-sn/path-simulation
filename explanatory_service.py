"""Production service for explanatory packages and per-job RAG chat sessions."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field

from config import Config
from explanatory_analysis.local_model import MODEL_DISPLAY_NAME, get_model_runtime


_ROOT = Path(__file__).resolve().parent


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _read(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".{uuid.uuid4().hex}.tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False) + "\n", encoding="utf-8")
    os.replace(temporary, path)


class RectContext(BaseModel):
    x: float = Field(..., ge=0, le=1)
    y: float = Field(..., ge=0, le=1)
    width: float = Field(..., gt=0, le=1)
    height: float = Field(..., gt=0, le=1)


class CustomZoneContext(BaseModel):
    id: str
    label: str
    rectNormalized: RectContext


class AnalysisContextUpdate(BaseModel):
    customZones: list[CustomZoneContext] = Field(default_factory=list)


class ChatSessionCreate(BaseModel):
    title: str | None = None


class ChatSessionPatch(BaseModel):
    title: str = Field(..., min_length=1, max_length=80)


class ChatMessageCreate(BaseModel):
    text: str = Field(..., min_length=1, max_length=4000)


class ExplanatoryManager:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._processes: dict[str, subprocess.Popen] = {}

    @staticmethod
    def job_dir(job_id: str) -> Path:
        if not job_id or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for char in job_id):
            raise ValueError("jobId tidak valid")
        return Path(Config.WORKDIR) / job_id

    def _assert_job(self, job_id: str) -> Path:
        directory = self.job_dir(job_id)
        if not (directory / "job.json").is_file():
            raise FileNotFoundError("job tidak ditemukan")
        return directory

    @staticmethod
    def _status_path(directory: Path) -> Path:
        return directory / "explanatory-status.json"

    @staticmethod
    def _package_path(directory: Path) -> Path:
        return directory / "explanatory-v2"

    def _ensure_context(self, directory: Path) -> dict[str, Any]:
        path = directory / "analysis-context.json"
        if path.is_file():
            return _read(path)
        job = _read(directory / "job.json")
        venue = job.get("venue") or {}
        width, height = float(venue.get("widthM") or 0), float(venue.get("heightM") or 0)
        from explanatory_analysis.pipeline import venue_fingerprint

        floorplan_value = venue.get("floorPlanPath")
        floorplan = Path(floorplan_value).expanduser() if floorplan_value else None
        fingerprint = venue_fingerprint(floorplan, width, height)
        tables = []
        for item in venue.get("tables") or []:
            rect = item.get("rectNormalized") or {}
            x, y = float(rect.get("x", 0)), float(rect.get("y", 0))
            w, h = float(rect.get("width", 0)), float(rect.get("height", 0))
            points_normalized = [[x, y], [x + w, y], [x + w, y + h], [x, y + h]]
            points_m = [[px * width, py * height] for px, py in points_normalized]
            tables.append({
                "featureId": str(item.get("id") or f"table-{len(tables) + 1:02d}"),
                "label": str(item.get("label") or f"Meja {len(tables) + 1}"),
                "type": "table",
                "verified": bool(item.get("verified", True)),
                "geometryM": {"type": "polygon", "points": points_m},
                "geometryNormalized": {"type": "polygon", "points": points_normalized},
            })
        context = {
            "schemaVersion": "2.0",
            "contextRevision": 1,
            "venueFingerprint": fingerprint,
            "coordinateSystem": {"unit": "meter", "orientation": "x_right_y_down", "widthM": width, "heightM": height},
            "tables": tables,
            "customZones": [],
        }
        _atomic(path, context)
        return context

    def status(self, job_id: str) -> dict[str, Any]:
        directory = self._assert_job(job_id)
        context = self._ensure_context(directory)
        path = self._status_path(directory)
        status = _read(path) if path.is_file() else {
            "jobId": job_id,
            "state": "ready" if (self._package_path(directory) / "manifest.json").is_file() else "not_started",
            "progress": 1.0 if (self._package_path(directory) / "manifest.json").is_file() else 0.0,
            "error": None,
        }
        with self._lock:
            process = self._processes.get(job_id)
        if process is not None and process.poll() is None:
            status.update(state="building", progress=max(float(status.get("progress") or 0), 0.05), error=None)
        elif status.get("state") == "building" and process is not None:
            if process.returncode != 0:
                status.update(state="error", error=f"explanatory worker berhenti dengan exit {process.returncode}")
                _atomic(path, status)
        capabilities_path = self._package_path(directory) / "capability_catalog.json"
        capabilities = _read(capabilities_path).get("capabilities", {}) if capabilities_path.is_file() else {}
        public_status = {key: value for key, value in status.items() if key != "packagePath"}
        return {
            **public_status,
            "contextRevision": int(context.get("contextRevision") or 1),
            "packageSchemaVersion": "2.0" if (self._package_path(directory) / "manifest.json").is_file() else None,
            "capabilities": capabilities,
            **self._model_status(),
        }

    def _model_status(self) -> dict[str, Any]:
        status = get_model_runtime().status()
        status.pop("modelPath", None)
        return status

    def build(self, job_id: str, force: bool = False) -> dict[str, Any]:
        directory = self._assert_job(job_id)
        self._ensure_context(directory)
        if not (directory / "result.json").is_file() or not (directory / "trajectories.parquet").is_file():
            raise RuntimeError("hasil utama atau trajectories.parquet belum tersedia")
        with self._lock:
            active = self._processes.get(job_id)
            if active is not None and active.poll() is None:
                return self.status(job_id)
            if not force and (self._package_path(directory) / "manifest.json").is_file():
                current = self.status(job_id)
                if current.get("state") == "ready":
                    return current
            status = {"jobId": job_id, "state": "building", "progress": 0.05, "error": None, "updatedAt": _now()}
            _atomic(self._status_path(directory), status)
            process = subprocess.Popen(
                [sys.executable, str(_ROOT / "explanatory_worker.py"), job_id],
                cwd=str(_ROOT),
            )
            self._processes[job_id] = process
        return self.status(job_id)

    def update_context(self, job_id: str, update: AnalysisContextUpdate) -> dict[str, Any]:
        directory = self._assert_job(job_id)
        context = self._ensure_context(directory)
        context["customZones"] = [zone.model_dump() for zone in update.customZones]
        context["contextRevision"] = int(context.get("contextRevision") or 1) + 1
        _atomic(directory / "analysis-context.json", context)
        _atomic(self._status_path(directory), {
            "jobId": job_id, "state": "stale", "progress": 0.0, "error": None, "updatedAt": _now()
        })
        return self.build(job_id, force=True)


class ChatSessionManager:
    def __init__(self, explanatory: ExplanatoryManager) -> None:
        self.explanatory = explanatory
        self._lock = threading.Lock()

    def _root(self, job_id: str) -> Path:
        directory = self.explanatory._assert_job(job_id)
        return directory / "llm-rag-v2" / "sessions"

    def _session_dir(self, job_id: str, session_id: str) -> Path:
        if not session_id or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for char in session_id):
            raise ValueError("sessionId tidak valid")
        return self._root(job_id) / session_id

    def _load(self, job_id: str, session_id: str) -> dict[str, Any]:
        path = self._session_dir(job_id, session_id) / "session.json"
        if not path.is_file():
            raise FileNotFoundError("sesi chat tidak ditemukan")
        session = _read(path)
        if session.get("jobId") != job_id:
            raise ValueError("sesi chat bukan milik job ini")
        return session

    def list(self, job_id: str) -> list[dict[str, Any]]:
        root = self._root(job_id)
        if not root.is_dir():
            return []
        sessions = []
        for path in root.glob("*/session.json"):
            try:
                session = _read(path)
                if session.get("jobId") == job_id:
                    sessions.append(self._summary(session))
            except (OSError, json.JSONDecodeError):
                continue
        return sorted(sessions, key=lambda item: item["updatedAt"], reverse=True)

    @staticmethod
    def _summary(session: dict[str, Any]) -> dict[str, Any]:
        return {
            "sessionId": session["sessionId"],
            "jobId": session["jobId"],
            "title": session["title"],
            "createdAt": session["createdAt"],
            "updatedAt": session["updatedAt"],
            "contextRevision": session["contextRevision"],
            "messageCount": len(session.get("messages") or []),
        }

    def create(self, job_id: str, request: ChatSessionCreate) -> dict[str, Any]:
        status = self.explanatory.status(job_id)
        session_id = uuid.uuid4().hex[:12]
        now = _now()
        session = {
            "schemaVersion": "1.0",
            "sessionId": session_id,
            "jobId": job_id,
            "title": (request.title or "Chat Baru").strip()[:80] or "Chat Baru",
            "createdAt": now,
            "updatedAt": now,
            "contextRevision": status["contextRevision"],
            "messages": [],
        }
        _atomic(self._session_dir(job_id, session_id) / "session.json", session)
        return session

    def get(self, job_id: str, session_id: str) -> dict[str, Any]:
        return self._load(job_id, session_id)

    def rename(self, job_id: str, session_id: str, request: ChatSessionPatch) -> dict[str, Any]:
        with self._lock:
            session = self._load(job_id, session_id)
            session["title"] = request.title.strip()[:80]
            session["updatedAt"] = _now()
            _atomic(self._session_dir(job_id, session_id) / "session.json", session)
        return session

    def delete(self, job_id: str, session_id: str) -> None:
        directory = self._session_dir(job_id, session_id)
        self._load(job_id, session_id)
        shutil.rmtree(directory)

    def ask(self, job_id: str, session_id: str, request: ChatMessageCreate) -> dict[str, Any]:
        status = self.explanatory.status(job_id)
        if status["state"] != "ready":
            raise RuntimeError(f"explanatory package belum siap: {status['state']}")
        if not status.get("modelReady"):
            raise ConnectionError("Runtime llama.cpp atau Qwen3-8B belum siap")
        with self._lock:
            session = self._load(job_id, session_id)
            package_path = self.explanatory.job_dir(job_id) / "explanatory-v2"
            from explanatory_analysis.rag import LocalRAG, RAGConfig, load_package

            config = RAGConfig(
                backend_root=_ROOT,
                output_root=Path(Config.WORKDIR),
                chat_model=MODEL_DISPLAY_NAME,
            )
            runs = self._session_dir(job_id, session_id) / "runs"
            rag = LocalRAG(config, load_package(package_path), run_root=runs, session_id=session_id)
            previous = [message.get("response") for message in session.get("messages", []) if message.get("response")]
            rag.history = previous[-6:]
            result = rag.ask(request.text.strip(), show=False)
            run_id = str((result.get("artifacts") or {}).get("runId") or "")
            overlay_value = (result.get("artifacts") or {}).get("floorplanOverlay")
            media = []
            if overlay_value:
                overlay = Path(overlay_value).resolve()
                if overlay.is_file() and overlay.is_relative_to(Path(Config.WORKDIR).resolve()):
                    try:
                        from PIL import Image
                        with Image.open(overlay) as image:
                            width, height = image.size
                    except Exception:
                        width, height = 0, 0
                    url = (
                        f"/jobs/{job_id}/chat-sessions/{session_id}/runs/"
                        f"{run_id}/artifacts/floorplan_overlay.png"
                    )
                    area = result.get("selectedArea") or {}
                    media.append({
                        "mediaId": f"{run_id}-floorplan",
                        "kind": "floorplanOverlay",
                        "mimeType": "image/png",
                        "artifactURL": url,
                        "thumbnailURL": url,
                        "caption": str(area.get("label") or result.get("selectedAreaId") or "Area floorplan"),
                        "width": width,
                        "height": height,
                        "selectedAreaId": result.get("selectedAreaId"),
                        "areaKind": area.get("kind"),
                        "supportLevel": result.get("supportLevel"),
                        "confidence": area.get("confidence"),
                        "metricSummary": {str(key): str(value) for key, value in list((area.get("metrics") or {}).items())[:3]},
                        "limitations": result.get("limitations") or [],
                    })
            now = _now()
            if not session.get("messages") and session.get("title") == "Chat Baru":
                session["title"] = request.text.strip().replace("\n", " ")[:50]
            entry = {
                "messageId": uuid.uuid4().hex,
                "runId": run_id,
                "role": "exchange",
                "question": request.text.strip(),
                "text": result.get("answer") or "",
                "supportLevel": result.get("supportLevel"),
                "selectedAreaId": result.get("selectedAreaId"),
                "selectedArea": result.get("selectedArea"),
                "selectedAreaKind": (result.get("selectedArea") or {}).get("kind"),
                "selectedAreaLabel": (result.get("selectedArea") or {}).get("label"),
                "selectedAreaConfidence": (result.get("selectedArea") or {}).get("confidence"),
                "metricSummary": {
                    str(key): str(value)
                    for key, value in list(((result.get("selectedArea") or {}).get("metrics") or {}).items())[:5]
                },
                "evidence": result.get("evidenceCardIds") or [],
                "limitations": result.get("limitations") or [],
                "contextRevision": status["contextRevision"],
                "media": media,
                "createdAt": now,
                "response": result,
            }
            session.setdefault("messages", []).append(entry)
            session["contextRevision"] = status["contextRevision"]
            session["updatedAt"] = now
            _atomic(self._session_dir(job_id, session_id) / "session.json", session)
        return {key: value for key, value in entry.items() if key != "response"}
