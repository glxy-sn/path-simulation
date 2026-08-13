from __future__ import annotations

import hashlib
import html
import json
import os
import re
import shutil
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Protocol

import matplotlib
matplotlib.use("Agg", force=True)
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Ellipse, Polygon as MplPolygon
from shapely.geometry import LineString, Point, Polygon, box
from sklearn.feature_extraction.text import TfidfVectorizer

from .local_model import MODEL_DISPLAY_NAME, get_model_runtime


@dataclass(frozen=True)
class RAGConfig:
    backend_root: Path
    output_root: Path
    chat_model: str = MODEL_DISPLAY_NAME
    top_k: int = 6
    num_ctx: int = 12288
    answer_num_predict: int = 4096

    @classmethod
    def default(cls, backend_root: Path | None = None) -> "RAGConfig":
        root = (backend_root or _find_backend_root()).resolve()
        output = Path(
            os.getenv("FOODCOURT_ANALYSIS_OUTPUT_ROOT", str(root / "notebooks" / "output"))
        ).expanduser().resolve()
        return cls(
            root,
            output,
            os.getenv("FOODCOURT_LLM_MODEL_NAME", MODEL_DISPLAY_NAME),
            int(os.getenv("FOODCOURT_RETRIEVAL_TOP_K", "6")),
            int(os.getenv("FOODCOURT_LLM_NUM_CTX", "12288")),
            int(os.getenv("FOODCOURT_ANSWER_NUM_PREDICT", "4096")),
        )


@dataclass(frozen=True)
class Package:
    path: Path
    job_id: str
    manifest: dict[str, Any]
    summary: dict[str, Any]
    areas: list[dict[str, Any]]
    cards: list[dict[str, Any]]
    capabilities: dict[str, Any]


class TextGenerator(Protocol):
    def generate(self, messages: list[dict[str, str]], max_tokens: int = 256) -> dict[str, Any]: ...


def _find_backend_root() -> Path:
    current = Path.cwd().resolve()
    for candidate in (current, *current.parents):
        if (candidate / "notebooks").is_dir() and (candidate / "explanatory_analysis").is_dir():
            return candidate
    raise RuntimeError("Root be/path-simulation tidak ditemukan.")


def _read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: Path, value: Any) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )


def load_package(package_path: str | Path) -> Package:
    package_path = Path(package_path).expanduser().resolve()
    required = [
        "manifest.json", "summary.json", "spatial_areas.json",
        "evidence_cards.jsonl", "capability_catalog.json",
    ]
    missing = [name for name in required if not (package_path / name).is_file()]
    if missing:
        raise FileNotFoundError(f"Package v2 tidak lengkap: {missing}")
    manifest = _read_json(package_path / "manifest.json")
    if str(manifest.get("schemaVersion")) != "2.0":
        raise ValueError("Tanya Data membutuhkan explanatory package schema 2.0.")
    with (package_path / "evidence_cards.jsonl").open(encoding="utf-8") as handle:
        cards = [json.loads(line) for line in handle if line.strip()]
    return Package(
        package_path,
        str(manifest["jobId"]),
        manifest,
        _read_json(package_path / "summary.json"),
        _read_json(package_path / "spatial_areas.json")["areas"],
        cards,
        _read_json(package_path / "capability_catalog.json"),
    )


def load_latest_package(config: RAGConfig | None = None) -> Package:
    config = config or RAGConfig.default()
    pointer = config.output_root / "latest.json"
    if not pointer.is_file():
        raise FileNotFoundError("latest.json belum tersedia; jalankan analysis terlebih dahulu.")
    latest = _read_json(pointer)
    return load_package(Path(latest["packagePath"]).expanduser().resolve())


def evidence_text(card: dict[str, Any]) -> str:
    return "\n".join([
        "jenis: " + " ".join(card.get("questionTypes") or []),
        "pernyataan: " + str(card.get("statement") or ""),
        "metrik: " + json.dumps(card.get("metrics") or {}, ensure_ascii=False, sort_keys=True),
        "keterbatasan: " + str(card.get("limitation") or ""),
    ])


KIND_LABELS = {
    "presence_hotspot": "Area kehadiran",
    "flow_hotspot": "Area arus",
    "low_presence_area": "Area kehadiran rendah",
    "low_flow_area": "Area arus rendah",
    "crowd_zone": "Area keramaian",
    "stop_cluster": "Area berhenti",
    "bottleneck_area": "Area bottleneck",
    "route_archetype": "Rute",
    "table": "Meja",
    "custom_zone": "Zona",
}


class LocalRAG:
    """General data retrieval followed by one Qwen reasoning-and-answer call."""

    def __init__(
        self,
        config: RAGConfig | None = None,
        package: Package | None = None,
        run_root: str | Path | None = None,
        session_id: str | None = None,
        generator: TextGenerator | None = None,
    ) -> None:
        self.config = config or RAGConfig.default()
        self.package = package or load_latest_package(self.config)
        self.generator = generator or get_model_runtime()
        self.documents = [evidence_text(card) for card in self.package.cards]
        self.area_by_id = {str(area["areaId"]): area for area in self.package.areas}
        if len(self.area_by_id) != len(self.package.areas):
            raise ValueError("Package memiliki areaId duplikat.")
        for area in self.package.areas:
            self._validate_official_geometry(area)
            if area.get("interactionGeometryM"):
                self._validate_official_geometry({
                    "areaId": str(area["areaId"]) + ":interaction",
                    "geometryM": area["interactionGeometryM"],
                })
        self.run_root = Path(run_root).expanduser().resolve() if run_root else None
        self.session_id = session_id or uuid.uuid4().hex[:12]
        self.history: list[dict[str, Any]] = []
        self._vectorizer: TfidfVectorizer | None = None
        self._document_matrix: Any | None = None

    def new_session(self) -> str:
        self.session_id = uuid.uuid4().hex[:12]
        self.history.clear()
        return self.session_id

    def health(self) -> dict[str, Any]:
        status = getattr(self.generator, "status", lambda: {})()
        return {**status, "ready": bool(status.get("modelReady", True))}

    def prepare_index(self) -> dict[str, Any]:
        self._ensure_tfidf()
        return {
            "documentCount": len(self.documents),
            "model": "tfidf",
            "datasetCount": len(list(self.package.path.glob("*.parquet"))) + 2,
        }

    def _ensure_tfidf(self) -> None:
        if self._document_matrix is not None or not self.documents:
            return
        self._vectorizer = TfidfVectorizer(ngram_range=(1, 2), strip_accents="unicode")
        self._document_matrix = self._vectorizer.fit_transform(self.documents)

    def semantic_hints(self, question: str, limit: int = 3) -> list[dict[str, Any]]:
        self._ensure_tfidf()
        if self._document_matrix is None or self._vectorizer is None:
            return []
        query = self._vectorizer.transform([question])
        scores = (self._document_matrix @ query.T).toarray().ravel()
        order = np.argsort(-scores, kind="stable")[: min(limit, len(scores))]
        return [
            {
                **self.package.cards[int(index)],
                "retrievalScore": float(scores[int(index)]),
                "retrievalMode": "tfidf",
            }
            for index in order
        ]

    def retrieve(self, question: str) -> list[dict[str, Any]]:
        return self.semantic_hints(question, self.config.top_k)

    def _session_context(self) -> list[dict[str, Any]]:
        return [
            {
                "question": item.get("question"),
                "answer": str(item.get("answer") or "")[:320],
                "selectedAreaLabel": self._area_label(item.get("selectedArea")),
            }
            for item in self.history[-6:]
        ]

    def _area_label(self, area: dict[str, Any] | None) -> str | None:
        if not area:
            return None
        explicit = str(area.get("label") or "").strip()
        if explicit:
            return explicit
        area_id = str(area.get("areaId") or "")
        suffix = area_id.rsplit("-", 1)[-1].lstrip("0") or "1"
        return f"{KIND_LABELS.get(str(area.get('kind')), 'Area')} {suffix}"

    def _hide_internal_area_ids(self, text: str) -> str:
        visible = text
        for area_id in sorted(self.area_by_id, key=len, reverse=True):
            label = self._area_label(self.area_by_id[area_id]) or "area tersebut"
            visible = re.sub(rf"(?<![\w-]){re.escape(area_id)}(?![\w-])", label, visible, flags=re.I)
        return visible

    @staticmethod
    def _compact_area(area: dict[str, Any]) -> str:
        def value_text(value: Any) -> str:
            return f"{value:.6g}" if isinstance(value, float) else str(value)

        metrics = ",".join(
            f"{key}={value_text(value)}"
            for key, value in (area.get("metrics") or {}).items()
        )
        return "|".join([
            str(area.get("areaId") or ""),
            str(area.get("label") or ""),
            str(area.get("kind") or ""),
            metrics,
        ])

    def _model_messages(self, question: str, evidence: list[dict[str, Any]]) -> list[dict[str, str]]:
        context = {
            "question": question,
            "analysisSummary": self.package.summary,
            "coordinateSystem": self.package.manifest.get("coordinateSystem") or {},
            "areaCatalogFormat": "one row per area: areaId|label|kind|metric=value,...",
            "areaCatalog": "\n".join(self._compact_area(area) for area in self.package.areas),
            "retrievedEvidence": [
                {
                    "cardId": card.get("cardId"),
                    "questionTypes": card.get("questionTypes") or [],
                    "statement": card.get("statement"),
                    "areaId": card.get("areaId"),
                    "metrics": card.get("metrics") or {},
                    "limitation": card.get("limitation"),
                }
                for card in evidence
            ],
            "capabilities": self.package.capabilities,
            "recentConversation": self._session_context(),
        }
        system = (
            "/think\nAnda adalah analis data CCTV spasial. Jawab pertanyaan pengguna dalam Bahasa Indonesia "
            "dengan melakukan penalaran sendiri atas seluruh areaCatalog, retrievedEvidence, capability, dan konteks percakapan. "
            "Tidak ada daftar intent atau jawaban yang sudah ditentukan oleh backend. Untuk pertanyaan perbandingan, tentukan objek "
            "yang dimaksud dari bahasa pengguna, bandingkan semua objek sejenis di areaCatalog, pilih metrik yang paling relevan, "
            "dan sebutkan dasar angkanya. Jika istilah seperti ramai dapat berarti beberapa hal, jelaskan interpretasi metrik yang dipakai "
            "atau bandingkan visitCount dan uniqueVisitors. visitCount adalah jumlah episode kunjungan; uniqueVisitors adalah jumlah ID track "
            "anonim unik, bukan jumlah orang terverifikasi. Jangan mengarang metrik, kondisi, atau kesimpulan yang tidak ada di data. "
            "CCTV tidak membuktikan identitas orang, kenyamanan, kebisingan, kepuasan, pembelian, atau sebab-akibat kecuali data memang "
            "menyediakannya. Jawab ringkas tetapi cukup menjelaskan alasan. Jangan tampilkan proses berpikir internal. "
            "Pada akhir jawaban, tulis marker [[SUPPORT:supported]], [[SUPPORT:partially_supported]], atau [[SUPPORT:unsupported]] "
            "sesuai kecukupan data, lalu [[AREA_ID:id-yang-persis]] jika satu area paling relevan untuk highlight; gunakan [[AREA_ID:none]] "
            "jika tidak ada satu area. Marker bukan bagian dari jawaban pengguna."
        )
        return [
            {"role": "system", "content": system},
            {"role": "user", "content": json.dumps(context, ensure_ascii=False, separators=(",", ":"))},
        ]

    def _model_answer(
        self,
        question: str,
        evidence: list[dict[str, Any]],
    ) -> tuple[str, str | None, str, str, dict[str, Any]]:
        started = time.perf_counter()
        result = self.generator.generate(
            self._model_messages(question, evidence),
            max_tokens=self.config.answer_num_predict,
        )
        finish_reason = str(result.get("finishReason") or "").casefold()
        if finish_reason in {"length", "max_tokens"}:
            raise RuntimeError(
                "Jawaban Qwen mencapai batas generasi sebelum selesai. "
                "Naikkan FOODCOURT_ANSWER_NUM_PREDICT atau ringkas konteks analisis."
            )
        text = str(result.get("text") or "").strip()
        marker = re.search(r"\[\[\s*AREA_ID\s*:\s*([^\]]+)\]\]", text, flags=re.I)
        reported_id = marker.group(1).strip() if marker else None
        support_marker = re.search(r"\[\[\s*SUPPORT\s*:\s*([^\]]+)\]\]", text, flags=re.I)
        reported_support = support_marker.group(1).strip().casefold() if support_marker else None
        answer = re.sub(r"\s*\[\[\s*AREA_ID\s*:\s*[^\]]+\]\]\s*", "", text, flags=re.I).strip()
        answer = re.sub(r"\s*\[\[\s*SUPPORT\s*:\s*[^\]]+\]\]\s*", "", answer, flags=re.I).strip()
        # Jangan bocorkan marker kontrol jika model berhenti tepat di tengah marker.
        answer = re.sub(
            r"\s*\[\[\s*(?:AREA_ID|SUPPORT)\s*:[^\]\r\n]*$",
            "",
            answer,
            flags=re.I,
        ).strip()
        answer = self._hide_internal_area_ids(answer)
        if not answer:
            raise RuntimeError("Qwen3-8B tidak menghasilkan jawaban yang dapat ditampilkan.")
        selected_id = None
        if reported_id and reported_id.casefold() != "none":
            selected_id = next(
                (area_id for area_id in self.area_by_id if area_id.casefold() == reported_id.casefold()),
                None,
            )
        valid_support = {"supported", "partially_supported", "unsupported"}
        support_level = reported_support if reported_support in valid_support else "partially_supported"
        usage = {
            "modelCallCount": 1,
            "promptTokens": result.get("promptTokens"),
            "completionTokens": result.get("completionTokens"),
            "finishReason": result.get("finishReason"),
            "durationMs": (time.perf_counter() - started) * 1000.0,
            "fallback": False,
            "thinkingAvailable": bool(str(result.get("thinking") or "").strip()),
            "areaMarkerValid": reported_id is None or reported_id.casefold() == "none" or selected_id is not None,
            "supportMarkerValid": reported_support in valid_support,
        }
        return answer, selected_id, support_level, str(result.get("thinking") or "").strip(), usage

    def ask(self, question: str, show: bool = True) -> dict[str, Any]:
        if not question.strip():
            raise ValueError("Pertanyaan tidak boleh kosong.")
        started = time.perf_counter()
        evidence = self.retrieve(question)
        answer, selected_id, support_level, thinking, generation_usage = self._model_answer(question, evidence)
        selected = self.area_by_id.get(selected_id) if selected_id else None
        limitations = list(dict.fromkeys(
            str(value).strip()
            for value in [
                selected.get("limitation") if selected else None,
                *(card.get("limitation") for card in evidence),
            ]
            if value and str(value).strip()
        ))
        metric_summary = {
            str(key): f"{float(value):.3g}" if isinstance(value, (int, float)) else str(value)
            for key, value in (selected.get("metrics") or {}).items()
        } if selected else {}
        grounding = {
            "mode": "qwen_general_reasoning",
            "catalogAreaCount": len(self.package.areas),
            "retrievedEvidenceCardIds": [card["cardId"] for card in evidence],
            "selectedAreaIdReportedByModel": selected_id,
            "thinkingAvailable": bool(thinking),
        }
        final = {
            "schemaVersion": "2.1",
            "pipelineVersion": "general-retrieval-qwen-reasoning-v2",
            "jobId": self.package.job_id,
            "sessionId": self.session_id,
            "contextRunIds": [
                str((item.get("artifacts") or {}).get("runId"))
                for item in self.history[-6:]
                if (item.get("artifacts") or {}).get("runId")
            ],
            "question": question,
            "supportLevel": support_level,
            "dataGrounding": "grounded" if evidence or self.package.areas else "general_knowledge",
            "interpretation": "Qwen menganalisis katalog area dan evidence dari job aktif sesuai pertanyaan pengguna.",
            "assumption": "Jawaban dan pemilihan area berasal dari reasoning Qwen atas data yang di-retrieve; backend hanya memvalidasi areaId untuk overlay.",
            "alternativeInterpretations": [],
            "answer": answer,
            "selectedAreaId": selected_id,
            "selectedArea": selected,
            "metricSummary": metric_summary,
            "evidenceCardIds": [card["cardId"] for card in evidence],
            "limitations": limitations,
            "requiredData": [],
            "grounding": grounding,
            "coordinateSystem": self.package.manifest["coordinateSystem"],
            "provenance": {
                "packagePath": str(self.package.path),
                "packageSchemaVersion": self.package.manifest["schemaVersion"],
                "chatModel": self.config.chat_model,
                "retrievalModel": "tfidf",
                "areaSelectionAuthority": "qwen_reasoning_validated",
            },
            "usage": {
                "generation": generation_usage,
                "pipelineLatencyMs": (time.perf_counter() - started) * 1000.0,
            },
        }
        retrieval_audit = {
            "selectionReason": "complete spatial area catalog + TF-IDF evidence -> Qwen general reasoning",
            "catalogAreaIds": list(self.area_by_id),
            "cards": evidence,
        }
        run_dir = self._save_run(final, retrieval_audit, final["grounding"], thinking)
        final["artifacts"] = {
            "runId": run_dir.name,
            "runDirectory": str(run_dir),
            "response": str(run_dir / "response.json"),
            "retrievedEvidence": str(run_dir / "retrieved_evidence.json"),
            "grounding": str(run_dir / "grounding.json"),
        }
        overlay = None
        try:
            overlay = self._render_overlay(run_dir, final)
        except Exception as error:
            final["limitations"] = list(dict.fromkeys([
                *final["limitations"], f"Overlay floorplan tidak dapat dibuat: {error}",
            ]))
        final["artifacts"]["floorplanOverlay"] = str(overlay) if overlay else None
        _write_json(run_dir / "response.json", final)
        (run_dir / "answer.md").write_text(final["answer"] + "\n", encoding="utf-8")
        _write_json(run_dir / "run_manifest.json", {
            "schemaVersion": "2.1",
            "pipelineVersion": final["pipelineVersion"],
            "runId": run_dir.name,
            "jobId": self.package.job_id,
            "sessionId": self.session_id,
            "models": {"answerer": self.config.chat_model, "retrieval": "tfidf"},
            "configuration": {
                "answerTokenBudget": self.config.answer_num_predict,
                "semanticTopK": self.config.top_k,
                "maximumModelCalls": 1,
                "thinking": True,
            },
            "usageAndLatency": final["usage"],
            "files": sorted(path.name for path in run_dir.iterdir()) + ["run_manifest.json"],
        })
        latest = run_dir.parent / "latest.json" if self.run_root else run_dir.parent.parent / "latest.json"
        temporary = latest.with_suffix(".tmp")
        _write_json(temporary, {
            "runId": run_dir.name,
            "runDirectory": str(run_dir),
            "response": str(run_dir / "response.json"),
            "floorplanOverlay": str(overlay) if overlay else None,
        })
        temporary.replace(latest)
        self.history.append(final)
        if show:
            self.display_result(final, evidence)
        return final

    def _save_run(
        self,
        final: dict[str, Any],
        retrieval: dict[str, Any],
        grounding: dict[str, Any],
        thinking: str = "",
    ) -> Path:
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        query_hash = hashlib.sha256(final["question"].encode()).hexdigest()[:8]
        runs = self.run_root or (self.config.output_root / self.package.job_id / "llm-rag-v2" / "runs")
        target = runs / f"{timestamp}-{query_hash}"
        staging = runs.parent / f".run.{uuid.uuid4().hex}.build"
        staging.mkdir(parents=True, exist_ok=False)
        try:
            _write_json(staging / "response.json", final)
            _write_json(staging / "retrieved_evidence.json", retrieval)
            _write_json(staging / "grounding.json", grounding)
            (staging / "answer.md").write_text(final["answer"] + "\n", encoding="utf-8")
            if thinking:
                (staging / "reasoning.txt").write_text(thinking + "\n", encoding="utf-8")
            target.parent.mkdir(parents=True, exist_ok=True)
            staging.rename(target)
        except Exception:
            if staging.exists():
                shutil.rmtree(staging)
            raise
        return target

    def _history_roots(self) -> list[tuple[Path, bool]]:
        if self.run_root:
            return [(self.run_root, False)]
        base = self.config.output_root / self.package.job_id
        return [(base / "llm-rag-v2" / "runs", False), (base / "llm-rag-v1" / "runs", True)]

    def saved_runs(self, limit: int = 100) -> list[dict[str, Any]]:
        entries: list[dict[str, Any]] = []
        for root, legacy_root in self._history_roots():
            if not root.is_dir():
                continue
            for run_dir in (path for path in root.iterdir() if path.is_dir()):
                response_path = run_dir / "response.json"
                if not response_path.is_file():
                    continue
                try:
                    response = _read_json(response_path)
                except (OSError, json.JSONDecodeError):
                    continue
                modern = (run_dir / "grounding.json").is_file() or (run_dir / "query_plan.json").is_file()
                entries.append({
                    "runId": run_dir.name,
                    "runDirectory": str(run_dir),
                    "question": str(response.get("question") or "(pertanyaan tidak tersedia)"),
                    "supportLevel": str(response.get("supportLevel") or "unknown"),
                    "dataGrounding": str(response.get("dataGrounding") or "legacy"),
                    "legacy": legacy_root or not modern,
                    "hasOverlay": bool((response.get("artifacts") or {}).get("floorplanOverlay")),
                })
        entries.sort(key=lambda item: item["runId"], reverse=True)
        return entries[:limit]

    def load_saved_bundle(self, run_directory: str | Path) -> dict[str, Any]:
        run_dir = Path(run_directory).expanduser().resolve()
        allowed_roots = [root.resolve() for root, _ in self._history_roots()]
        if not any(run_dir.parent == root for root in allowed_roots):
            raise ValueError("Run directory berada di luar history job aktif.")
        response = _read_json(run_dir / "response.json")
        retrieval = _read_json(run_dir / "retrieved_evidence.json") if (run_dir / "retrieved_evidence.json").is_file() else {}
        grounding = _read_json(run_dir / "grounding.json") if (run_dir / "grounding.json").is_file() else None
        query_plan = _read_json(run_dir / "query_plan.json") if (run_dir / "query_plan.json").is_file() else None
        execution = _read_json(run_dir / "execution_result.json") if (run_dir / "execution_result.json").is_file() else None
        reasoning_path = run_dir / "reasoning.txt"
        legacy_thinking_path = run_dir / "thinking.txt"
        if reasoning_path.is_file():
            thinking = reasoning_path.read_text(encoding="utf-8")
        elif legacy_thinking_path.is_file():
            thinking = legacy_thinking_path.read_text(encoding="utf-8")
        else:
            thinking = ""
        return {
            "response": response,
            "evidence": list(retrieval.get("cards") or []),
            "grounding": grounding,
            "queryPlan": query_plan,
            "execution": execution,
            "thinking": thinking,
            "legacy": grounding is None and query_plan is None,
        }

    def load_saved_run(self, run_id: str) -> tuple[dict[str, Any], list[dict[str, Any]], str]:
        matches = [entry for entry in self.saved_runs(limit=1000) if entry["runId"] == run_id]
        if not matches:
            raise FileNotFoundError(f"Riwayat run tidak ditemukan: {run_id}")
        bundle = self.load_saved_bundle(matches[0]["runDirectory"])
        return bundle["response"], bundle["evidence"], bundle["thinking"]

    def _validate_official_geometry(self, area: dict[str, Any]) -> None:
        geometry = area.get("geometryM") or {}
        kind = geometry.get("type")
        coordinate = self.package.manifest["coordinateSystem"]
        venue = box(0, 0, float(coordinate["widthM"]), float(coordinate["heightM"]))
        if kind == "polygon":
            shape = Polygon(geometry.get("points") or [], geometry.get("holes") or None)
        elif kind == "circle":
            radius = float(geometry.get("radiusM", 0))
            shape = Point(*geometry["center"]).buffer(radius, quad_segs=48)
            if radius <= 0:
                raise ValueError(f"Radius area tidak valid: {area.get('areaId')}")
        elif kind == "ellipse":
            radii = np.asarray(geometry.get("radiiM"), dtype=float)
            center = np.asarray(geometry.get("center"), dtype=float)
            if radii.shape != (2,) or center.shape != (2,) or np.any(radii <= 0):
                raise ValueError(f"Ellipse area tidak valid: {area.get('areaId')}")
            angles = np.linspace(0, 2 * np.pi, 97)
            points = np.c_[radii[0] * np.cos(angles), radii[1] * np.sin(angles)]
            theta = np.radians(float(geometry.get("angleDeg", 0)))
            rotation = np.array([[np.cos(theta), -np.sin(theta)], [np.sin(theta), np.cos(theta)]])
            shape = Polygon(points @ rotation.T + center)
        elif kind == "polyline":
            shape = LineString(geometry.get("points") or [])
        else:
            raise ValueError(f"Geometry area tidak didukung: {area.get('areaId')} ({kind})")
        bounds = np.asarray(shape.bounds, dtype=float)
        if not shape.is_valid or shape.is_empty or bounds.shape != (4,) or not np.all(np.isfinite(bounds)) or shape.intersection(venue).is_empty:
            raise ValueError(f"Geometry resmi invalid atau tidak beririsan dengan venue: {area.get('areaId')}")

    def _render_overlay(self, run_dir: Path, final: dict[str, Any]) -> Path | None:
        area = final.get("selectedArea")
        if not area or final["dataGrounding"] == "general_knowledge":
            return None
        coordinate = self.package.manifest["coordinateSystem"]
        width, height = float(coordinate["widthM"]), float(coordinate["heightM"])
        floorplan_value = self.package.manifest.get("floorplan", {}).get("sourcePath")
        floorplan = Path(floorplan_value).expanduser() if floorplan_value else None
        color = "#f4a261" if final["supportLevel"] == "partially_supported" else "#0077b6"
        figure_height = max(3.0, 10.0 * height / max(width, 0.1))
        figure, axis = plt.subplots(figsize=(10, figure_height), frameon=False)
        figure.subplots_adjust(left=0, right=1, bottom=0, top=1)
        axis.set_position([0, 0, 1, 1])
        if floorplan and floorplan.is_file():
            axis.imshow(plt.imread(floorplan), origin="upper", extent=(0, width, height, 0), aspect="equal")
        else:
            axis.set_facecolor("#f6f7f9")
            for x in np.arange(0, width + 0.001, max(0.5, width / 10)):
                axis.axvline(x, color="#c7ccd4", alpha=0.25, linewidth=0.6, zorder=0)
            for y in np.arange(0, height + 0.001, max(0.5, height / 10)):
                axis.axhline(y, color="#c7ccd4", alpha=0.25, linewidth=0.6, zorder=0)
        self._draw_geometry(axis, area["geometryM"], color, self._area_label(area) or "Area terpilih")
        if area.get("interactionGeometryM"):
            self._draw_geometry(axis, area["interactionGeometryM"], "#2a9d8f", "interaction zone", alpha=0.12, dashed=True)
        axis.set(xlim=(0, width), ylim=(height, 0), aspect="equal")
        axis.set_axis_off()
        target = run_dir / "floorplan_overlay.png"
        figure.savefig(target, dpi=180, bbox_inches="tight", pad_inches=0)
        plt.close(figure)
        return target

    @staticmethod
    def _draw_geometry(axis: Any, geometry: dict[str, Any], color: str, label: str, alpha: float = 0.28, dashed: bool = False) -> None:
        style = "--" if dashed else "-"
        kind = geometry.get("type")
        if kind == "polygon":
            points = np.asarray(geometry["points"])
            patch = MplPolygon(points, closed=True, facecolor=color, edgecolor=color, linewidth=3, linestyle=style, alpha=alpha)
            axis.add_patch(patch)
            center = geometry.get("centroid") or points.mean(axis=0)
        elif kind == "circle":
            center = geometry["center"]
            patch = plt.Circle(center, geometry["radiusM"], facecolor=color, edgecolor=color, linewidth=3, linestyle=style, alpha=alpha)
            axis.add_patch(patch)
        elif kind == "ellipse":
            center = geometry["center"]
            patch = Ellipse(center, 2 * geometry["radiiM"][0], 2 * geometry["radiiM"][1], angle=geometry.get("angleDeg", 0), facecolor=color, edgecolor=color, linewidth=3, linestyle=style, alpha=alpha)
            axis.add_patch(patch)
        elif kind == "polyline":
            points = np.asarray(geometry["points"])
            axis.plot(points[:, 0], points[:, 1], color=color, linewidth=4, linestyle=style)
            center = points[len(points) // 2]
        else:
            raise ValueError(f"Geometry overlay tidak didukung: {kind}")
        axis.text(center[0], center[1], label, ha="center", va="bottom", color="white", fontsize=9, bbox={"boxstyle": "round", "facecolor": color, "alpha": 0.95, "edgecolor": "white"})

    @staticmethod
    def display_result(final: dict[str, Any], evidence: list[dict[str, Any]]) -> None:
        try:
            from IPython.display import HTML, Image, Markdown, display
        except ImportError as error:
            raise RuntimeError("display_result hanya tersedia di runtime notebook/IPython") from error
        badge_color = {"supported": "#2a9d8f", "partially_supported": "#f4a261", "unsupported": "#d62828"}.get(final.get("supportLevel"), "#6c757d")
        display(HTML(f"<span style='background:{badge_color};color:white;padding:4px 9px;border-radius:8px'>{html.escape(str(final.get('supportLevel')))}</span>"))
        display(Markdown("### Jawaban\n\n" + str(final.get("answer") or "")))
        overlay = (final.get("artifacts") or {}).get("floorplanOverlay")
        if overlay and Path(overlay).is_file():
            display(Image(filename=Path(overlay).as_posix()))

    def widget(self):
        import ipywidgets as widgets
        question = widgets.Textarea(value="Area mana yang paling sering dilewati?", placeholder="Tulis pertanyaan atau follow-up...", description="Pertanyaan", layout=widgets.Layout(width="100%", height="90px"))
        ask_button = widgets.Button(description="Ask Qwen3-8B", button_style="primary", icon="search")
        new_session_button = widgets.Button(description="Sesi baru", icon="plus")
        status = widgets.HTML(value=f"<b>Job:</b> {self.package.job_id} &nbsp; <b>Model:</b> {self.config.chat_model} &nbsp; <b>Session:</b> {self.session_id}")
        output = widgets.Output()

        def ask_clicked(_: Any) -> None:
            ask_button.disabled = True
            status.value = "Grounding data deterministik, lalu Qwen3-8B menyusun penjelasan..."
            with output:
                output.clear_output(wait=True)
                try:
                    self.ask(question.value, show=True)
                    status.value = f"Selesai · session {self.session_id} · {len(self.history)} turn."
                except Exception as error:
                    from IPython.display import HTML, display
                    display(HTML(f"<div style='color:#b00020'><b>Error:</b> {html.escape(str(error))}</div>"))
                    status.value = "Gagal; lihat detail error."
                finally:
                    ask_button.disabled = False

        def new_session(_: Any) -> None:
            self.new_session()
            question.value = ""
            output.clear_output()

        ask_button.on_click(ask_clicked)
        new_session_button.on_click(new_session)
        return widgets.VBox([status, question, widgets.HBox([ask_button, new_session_button]), output])
