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
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import matplotlib
matplotlib.use("Agg", force=True)
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.patches import Ellipse, Polygon as MplPolygon
from pydantic import ValidationError
from shapely.geometry import LineString, Point, Polygon, box
from sklearn.feature_extraction.text import TfidfVectorizer

from .query_engine import DataCatalog, NarratedAnswer, QueryExecutor, QueryPlan


@dataclass(frozen=True)
class RAGConfig:
    backend_root: Path
    output_root: Path
    ollama_url: str = "http://127.0.0.1:11434"
    chat_model: str = "qwen3:14b"
    embed_model: str = "qwen3-embedding:0.6b"
    top_k: int = 6
    num_ctx: int = 4096
    thinking_num_predict: int = 512
    thinking_retry_num_predict: int = 1024
    answer_num_predict: int = 256
    planner_thinking_mode: str = "adaptive"

    @classmethod
    def default(cls, backend_root: Path | None = None) -> "RAGConfig":
        root = (backend_root or _find_backend_root()).resolve()
        output = Path(os.getenv("FOODCOURT_ANALYSIS_OUTPUT_ROOT", str(root / "notebooks" / "output"))).expanduser().resolve()
        return cls(
            root,
            output,
            os.getenv("OLLAMA_BASE_URL", "http://127.0.0.1:11434").rstrip("/"),
            os.getenv("FOODCOURT_LLM_MODEL", "qwen3:14b"),
            os.getenv("FOODCOURT_EMBED_MODEL", "qwen3-embedding:0.6b"),
            int(os.getenv("FOODCOURT_RETRIEVAL_TOP_K", "6")),
            int(os.getenv("FOODCOURT_LLM_NUM_CTX", "4096")),
            int(os.getenv("FOODCOURT_THINKING_NUM_PREDICT", "512")),
            int(os.getenv("FOODCOURT_THINKING_RETRY_NUM_PREDICT", "1024")),
            int(os.getenv("FOODCOURT_ANSWER_NUM_PREDICT", "256")),
            os.getenv("FOODCOURT_PLANNER_THINKING_MODE", "adaptive").strip().lower(),
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


def _find_backend_root() -> Path:
    current = Path.cwd().resolve()
    for candidate in (current, *current.parents):
        if (candidate / "notebooks").is_dir() and (candidate / "explanatory_analysis").is_dir():
            return candidate
    raise RuntimeError("Root be/path-simulation tidak ditemukan.")


def _read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False) + "\n", encoding="utf-8")


def load_package(package_path: str | Path) -> Package:
    package_path = Path(package_path).expanduser().resolve()
    required = ["manifest.json", "summary.json", "spatial_areas.json", "evidence_cards.jsonl", "capability_catalog.json"]
    missing = [name for name in required if not (package_path / name).is_file()]
    if missing:
        raise FileNotFoundError(f"Package v2 tidak lengkap: {missing}")
    manifest = _read_json(package_path / "manifest.json")
    if str(manifest.get("schemaVersion")) != "2.0":
        raise ValueError("RAG membutuhkan explanatory package schema 2.0.")
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
        raise FileNotFoundError("latest.json belum tersedia; jalankan notebook analysis terlebih dahulu.")
    latest = _read_json(pointer)
    package_path = Path(latest["packagePath"]).expanduser().resolve()
    return load_package(package_path)


def evidence_text(card: dict[str, Any]) -> str:
    return "\n".join([
        "jenis: " + " ".join(card.get("questionTypes") or []),
        "pernyataan: " + str(card.get("statement") or ""),
        "area: " + str(card.get("areaId") or ""),
        "metrik: " + json.dumps(card.get("metrics") or {}, ensure_ascii=False, sort_keys=True),
        "keterbatasan: " + str(card.get("limitation") or ""),
    ])


class OllamaClient:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    def request(self, path: str, payload: dict[str, Any] | None = None, timeout: int = 600) -> dict[str, Any]:
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = Request(self.base_url + path, data=data, headers={"Content-Type": "application/json"}, method="GET" if payload is None else "POST")
        try:
            with urlopen(request, timeout=timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Ollama HTTP {error.code}: {detail}") from error
        except URLError as error:
            raise ConnectionError(f"Ollama tidak dapat dihubungi di {self.base_url}.") from error
        except TimeoutError as error:
            raise TimeoutError(f"Ollama timeout pada endpoint {path}.") from error

    def tags(self) -> list[str]:
        return sorted(model.get("name", "") for model in self.request("/api/tags", timeout=5).get("models", []))

    def embed(self, model: str, texts: list[str]) -> np.ndarray:
        response = self.request("/api/embed", {"model": model, "input": texts, "truncate": True})
        vectors = np.asarray(response.get("embeddings"), dtype=float)
        if vectors.ndim != 2 or vectors.shape[0] != len(texts):
            raise RuntimeError("Bentuk embedding Ollama tidak valid.")
        return vectors / np.maximum(np.linalg.norm(vectors, axis=1, keepdims=True), 1e-12)

    def chat(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self.request("/api/chat", payload, timeout=900)


class LocalRAG:
    def __init__(
        self,
        config: RAGConfig | None = None,
        package: Package | None = None,
        run_root: str | Path | None = None,
        session_id: str | None = None,
    ):
        self.config = config or RAGConfig.default()
        self.package = package or load_latest_package(self.config)
        self.client = OllamaClient(self.config.ollama_url)
        self.documents = [evidence_text(card) for card in self.package.cards]
        self._document_embeddings: np.ndarray | None = None
        self.area_by_id = {area["areaId"]: area for area in self.package.areas}
        if len(self.area_by_id) != len(self.package.areas):
            raise ValueError("Package memiliki areaId duplikat.")
        for area in self.package.areas:
            self._validate_official_geometry(area)
            if area.get("interactionGeometryM"):
                self._validate_official_geometry({"areaId": area["areaId"] + ":interaction", "geometryM": area["interactionGeometryM"]})
        self.card_by_id = {card["cardId"]: card for card in self.package.cards}
        self.catalog = DataCatalog(self.package.path, self.package.areas, self.package.summary)
        self.executor = QueryExecutor(self.catalog, self.area_by_id)
        self.run_root = Path(run_root).expanduser().resolve() if run_root else None
        self.session_id = session_id or uuid.uuid4().hex[:12]
        self.history: list[dict[str, Any]] = []

    def new_session(self) -> str:
        self.session_id = uuid.uuid4().hex[:12]
        self.history.clear()
        return self.session_id

    def health(self) -> dict[str, Any]:
        models = self.client.tags()
        normalized = {item.split(":latest")[0] for item in models}
        required = [self.config.chat_model, self.config.embed_model]
        missing = [item for item in required if item not in models and item.split(":latest")[0] not in normalized]
        return {"ollamaUrl": self.config.ollama_url, "installedModels": models, "requiredModels": required, "missingModels": missing, "ready": not missing}

    def prepare_index(self) -> dict[str, Any]:
        vectors = self._semantic_index()
        return {
            "documentCount": int(vectors.shape[0]),
            "embeddingDimension": int(vectors.shape[1]),
            "model": self.config.embed_model,
            "datasetCount": len(self.catalog.specs),
        }

    def _semantic_index(self) -> np.ndarray:
        if self._document_embeddings is not None:
            return self._document_embeddings
        digest = hashlib.sha256((self.config.embed_model + "\n" + "\n---\n".join(self.documents)).encode()).hexdigest()[:16]
        safe_model = re.sub(r"[^A-Za-z0-9_.-]+", "_", self.config.embed_model)
        cache_path = self.package.path.parent / "llm-rag-v2" / "cache" / f"{safe_model}-{digest}.npz"
        if cache_path.is_file():
            self._document_embeddings = np.load(cache_path)["embeddings"]
        else:
            self._document_embeddings = self.client.embed(self.config.embed_model, self.documents)
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            temporary = cache_path.with_suffix(".tmp.npz")
            np.savez_compressed(temporary, embeddings=self._document_embeddings)
            temporary.replace(cache_path)
        return self._document_embeddings

    def _semantic_scores(self, question: str) -> tuple[np.ndarray, str]:
        mode = "ollama_embedding"
        try:
            scores = self._semantic_index() @ self.client.embed(self.config.embed_model, [question])[0]
        except (ConnectionError, RuntimeError, TimeoutError):
            if not self.documents:
                return np.asarray([], dtype=float), "none"
            matrix = TfidfVectorizer(ngram_range=(1, 2), strip_accents="unicode").fit_transform(self.documents + [question])
            scores = (matrix[:-1] @ matrix[-1].T).toarray().ravel()
            mode = "tfidf"
        return scores, mode

    def semantic_hints(self, question: str, limit: int = 3) -> list[dict[str, Any]]:
        scores, mode = self._semantic_scores(question)
        if not len(scores):
            return []
        order = np.argsort(-scores, kind="stable")[: min(limit, len(scores))]
        return [
            {
                "cardId": self.package.cards[int(index)]["cardId"],
                "questionTypes": self.package.cards[int(index)].get("questionTypes") or [],
                "statement": self.package.cards[int(index)].get("statement"),
                "areaId": self.package.cards[int(index)].get("areaId"),
                "metrics": self.package.cards[int(index)].get("metrics") or {},
                "limitation": self.package.cards[int(index)].get("limitation"),
                "evidenceRefs": self.package.cards[int(index)].get("evidenceRefs") or [],
                "semanticScore": float(scores[int(index)]),
                "retrievalMode": mode,
            }
            for index in order
        ]

    def retrieve(self, question: str, execution: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        if not question.strip():
            raise ValueError("Pertanyaan tidak boleh kosong.")
        scores, mode = self._semantic_scores(question)
        card_score = {card["cardId"]: float(scores[index]) for index, card in enumerate(self.package.cards)} if len(scores) else {}
        forced_area_ids: list[str] = []
        if execution:
            if execution.get("selectedAreaId"):
                forced_area_ids.append(str(execution["selectedAreaId"]))
            forced_area_ids.extend(str(row["areaId"]) for row in execution.get("rows", []) if row.get("areaId"))
        selected: list[dict[str, Any]] = []
        seen: set[str] = set()
        for area_id in forced_area_ids:
            for card in self.package.cards:
                if card.get("areaId") == area_id and card["cardId"] not in seen:
                    item = dict(card)
                    item["retrievalScore"] = card_score.get(card["cardId"], 0.0)
                    item["retrievalMode"] = "executor_population+" + mode
                    selected.append(item); seen.add(card["cardId"])
                    break
        if len(scores):
            for index in np.argsort(-scores, kind="stable"):
                card = self.package.cards[int(index)]
                if card["cardId"] in seen:
                    continue
                item = dict(card)
                item["retrievalScore"] = float(scores[int(index)])
                item["retrievalMode"] = mode
                selected.append(item); seen.add(card["cardId"])
                if len(selected) >= max(self.config.top_k, len(forced_area_ids)):
                    break
        return selected[: max(self.config.top_k, min(20, len(forced_area_ids)))]

    def _session_context(self) -> list[dict[str, Any]]:
        return [
            {
                "runId": (item.get("artifacts") or {}).get("runId"),
                "question": item.get("question"),
                "interpretation": (item.get("queryPlan") or {}).get("interpretation"),
                "selectedAreaId": item.get("selectedAreaId"),
                "result": str(item.get("answer") or "")[:240],
            }
            for item in self.history[-6:]
        ]

    @staticmethod
    def _parse_json_model(content: str, model: type[QueryPlan] | type[NarratedAnswer]) -> QueryPlan | NarratedAnswer:
        cleaned = content.strip()
        if cleaned.startswith("```"):
            cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", cleaned, flags=re.I | re.S)
        return model.model_validate_json(cleaned)

    @staticmethod
    def _parse_query_plan(content: str, question: str) -> QueryPlan:
        """Parse planner JSON and repair only an omitted ranking direction.

        Qwen occasionally emits the correct dataset, kind, and metric but leaves
        ``direction`` at its schema default.  This deterministic repair does not
        select an area: it only maps explicit low/quiet wording to ``min`` and
        otherwise uses ``max`` for a rank/recommend operation.  The executor
        remains the sole selection authority.
        """
        cleaned = content.strip()
        if cleaned.startswith("```"):
            cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", cleaned, flags=re.I | re.S)
        payload = json.loads(cleaned)
        metrics = payload.get("metrics") or []
        if payload.get("operation") in {"rank", "recommend"} and metrics:
            directions = [str(metric.get("direction") or "none") for metric in metrics]
            if all(direction == "none" for direction in directions):
                question_text = question.lower()
                planner_text = " ".join([
                    str(payload.get("interpretation") or ""),
                    str(payload.get("assumption") or ""),
                ]).lower()
                low_markers = (
                    "paling sepi", "jarang", "terendah", "minimum", "terkecil",
                    "paling rendah", "least", "lowest", "minimum", "low activity",
                )
                high_markers = (
                    "paling ramai", "tertinggi", "maksimum", "terbesar", "paling tinggi",
                    "most", "highest", "maximum", "busiest", "most crowded",
                )
                if any(marker in question_text for marker in low_markers):
                    direction = "min"
                elif any(marker in question_text for marker in high_markers):
                    direction = "max"
                else:
                    direction = "min" if any(marker in planner_text for marker in low_markers) else "max"
                for metric in metrics:
                    metric["direction"] = direction
        return QueryPlan.model_validate(payload)

    def _planner_payload(
        self,
        question: str,
        hints: list[dict[str, Any]],
        budget: int,
        repair: str | None = None,
        thinking_enabled: bool = False,
    ) -> dict[str, Any]:
        relevant_datasets = {
            Path(reference).stem
            for hint in hints
            for reference in hint.get("evidenceRefs") or []
            if str(reference).endswith(".parquet")
        }
        if any(hint.get("areaId") for hint in hints):
            relevant_datasets.add("spatial_areas")
        compact_hints = [
            {
                "questionTypes": hint.get("questionTypes") or [],
                "evidenceRefs": hint.get("evidenceRefs") or [],
            }
            for hint in hints
        ]
        context = {
            "question": question,
            "dataCatalog": self.catalog.prompt_payload(relevant_datasets),
            "semanticConceptHints": compact_hints,
            "sessionContext": self._session_context(),
        }
        if repair:
            context["repairInstruction"] = repair
        system = """Anda adalah query planner trajectory. Buat keputusan singkat, lalu keluarkan QueryPlan JSON valid.
REASONING COMPACT: maksimal enam langkah pendek; jangan mengulang pertanyaan, catalog, schema, atau semua kandidat. Cukup tentukan interpretasi, dataset, populasi, metrik, operator, dan filter.
Aturan: pilih satu interpretasi; alternatif masuk alternativeInterpretations. Area kind wajib masuk entityKinds, bukan metrics. Dilarang membuat SQL, Python, geometry, field, kind, atau areaId baru. relativeIntensity hanya boleh dibandingkan dalam satu kind. Operasi rank/recommend WAJIB memberi direction min atau max pada sedikitnya satu metric; jangan gunakan none.
Untuk ranking spasial gunakan spatial_areas. "Jarang dilewati" = flow_hotspot, relativeIntensity/value/min. "Sepi" = presence rendah. Jika keduanya muncul, pilih frasa paling spesifik dan catat alternatif. low_flow_area hanya untuk permintaan eksplisit kandidat aktivitas rendah pada observed-support envelope.
Contoh: "area mana yang paling sepi atau yang jarang dilewati" => analytical; spatial_areas; rank; [flow_hotspot]; relativeIntensity/value/min; spatialAnswer true.
general_knowledge wajib tanpa dataset, metric, filter, area, timeRange, dan spatialAnswer. Klaim venue harus berbasis data. Follow-up boleh memakai sessionContext. message.content hanya JSON sesuai schema."""
        return {
            "model": self.config.chat_model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": json.dumps(context, ensure_ascii=False, separators=(",", ":"))}],
            "format": QueryPlan.model_json_schema(),
            "think": thinking_enabled,
            "stream": False,
            "options": {"temperature": 0.1, "seed": 42, "num_ctx": self.config.num_ctx, "num_predict": budget},
        }

    def plan_question(self, question: str) -> tuple[QueryPlan, str, dict[str, Any], list[dict[str, Any]]]:
        hints = self.semantic_hints(question)
        traces: list[str] = []
        attempts: list[dict[str, Any]] = []
        last_error = ""
        budgets = [self.config.thinking_num_predict, self.config.thinking_retry_num_predict]
        for attempt_index, budget in enumerate(budgets):
            if self.config.planner_thinking_mode not in {"adaptive", "always", "off"}:
                raise ValueError("FOODCOURT_PLANNER_THINKING_MODE harus adaptive, always, atau off")
            thinking_enabled = self.config.planner_thinking_mode == "always" or (
                self.config.planner_thinking_mode == "adaptive" and attempt_index > 0
            )
            repair = None if attempt_index == 0 else f"Plan sebelumnya tidak boleh dieksekusi: {last_error}. Buat QueryPlan valid dan ringkas."
            try:
                response = self.client.chat(
                    self._planner_payload(question, hints, budget, repair, thinking_enabled)
                )
            except (ConnectionError, RuntimeError, TimeoutError) as error:
                last_error = str(error)
                attempts.append({"attempt": attempt_index + 1, "budget": budget, "status": "error", "error": last_error})
                continue
            message = response.get("message") or {}
            trace = str(message.get("thinking") or "")
            if trace.strip():
                traces.append(f"=== Planner attempt {attempt_index + 1} ===\n{trace}")
            done_reason = response.get("done_reason")
            metadata = {
                "attempt": attempt_index + 1,
                "budget": budget,
                "thinkingEnabled": thinking_enabled,
                "doneReason": done_reason,
                "evalCount": response.get("eval_count"),
                "durationMs": float(response["total_duration"]) / 1_000_000.0 if response.get("total_duration") is not None else None,
            }
            if done_reason in {"length", "max_tokens"}:
                last_error = f"Planner terpotong oleh batas {budget} token."
                metadata.update({"status": "truncated", "error": last_error})
                attempts.append(metadata)
                continue
            try:
                plan = self._parse_query_plan(str(message.get("content") or ""), question)
                plan = self.catalog.normalize_plan(plan)
                self.catalog.validate_plan(plan, self.area_by_id)
            except (ValidationError, ValueError, json.JSONDecodeError, AssertionError) as error:
                last_error = str(error)
                metadata.update({"status": "invalid", "error": last_error})
                attempts.append(metadata)
                continue
            metadata["status"] = "valid"
            attempts.append(metadata)
            return plan, "\n\n".join(traces), {
                "status": "retry_succeeded" if attempt_index else "complete",
                "attempts": attempts,
                "usedAttempt": attempt_index + 1,
                "truncated": False,
                "thinkingMode": self.config.planner_thinking_mode,
            }, hints
        raise RuntimeError(f"Planner gagal setelah dua attempt: {last_error}")

    def _answer_payload(self, question: str, plan: QueryPlan, execution: dict[str, Any], evidence: list[dict[str, Any]], repair: str | None = None) -> dict[str, Any]:
        selected_area_id = execution.get("selectedAreaId")
        if selected_area_id and plan.operation in {"rank", "recommend"}:
            evidence = [card for card in evidence if card.get("areaId") == selected_area_id]
        clean_evidence = [
            {key: value for key, value in card.items() if key not in {"geometryM", "areaId"}}
            for card in evidence[:3]
        ]
        compact_execution = {
            key: execution.get(key)
            for key in (
                "status", "dataGrounding", "dataset", "operation",
                "populationCount", "metrics",
                "limitations", "requiredData",
            )
            if key in execution
        }
        row_limit = 1 if plan.operation in {"rank", "recommend"} else 10
        compact_execution["rows"] = [
            {key: value for key, value in row.items() if key != "areaId"}
            for row in list(execution.get("rows") or [])[:row_limit]
        ]
        context = {
            "question": question,
            "queryPlan": plan.model_dump(),
            "executionResult": compact_execution,
            "selectedAreaLabelReadOnly": self._official_area_label(execution) if selected_area_id else None,
            "evidence": clean_evidence,
        }
        if repair: context["repairInstruction"] = repair
        system = """Narasi 2-3 kalimat Bahasa Indonesia dari QueryPlan dan executionResult. Jika selectedAreaLabelReadOnly tidak null, itulah area resmi: sebut label ramah pengguna tersebut, nilai metrik utama, dan populasi pembanding; jangan memilih area lain dan jangan tampilkan ID internal. Simpan keterbatasan hanya di field limitations, jangan masukkan ke answer kecuali pengguna menanyakannya. Jangan hitung ulang, buat geometry, tambah label supported, atau tambah fakta venue. Untuk general_knowledge, tegaskan bukan hasil trajectory; untuk hybrid, pisahkan data dan saran. Keluarkan JSON schema tanpa thinking."""
        return {
            "model": self.config.chat_model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": json.dumps(context, ensure_ascii=False, separators=(",", ":"))}],
            "format": NarratedAnswer.model_json_schema(),
            "think": False,
            "stream": False,
            "options": {"temperature": 0.1, "seed": 42, "num_ctx": self.config.num_ctx, "num_predict": self.config.answer_num_predict},
        }

    def narrate(self, question: str, plan: QueryPlan, execution: dict[str, Any], evidence: list[dict[str, Any]]) -> tuple[NarratedAnswer, dict[str, Any]]:
        last_error = ""
        for attempt in range(2):
            repair = None if attempt == 0 else f"Respons JSON sebelumnya invalid: {last_error}. Perbaiki tanpa mengubah hasil executor."
            try:
                response = self.client.chat(self._answer_payload(question, plan, execution, evidence, repair))
                candidate = self._parse_json_model(str((response.get("message") or {}).get("content") or ""), NarratedAnswer)
                assert isinstance(candidate, NarratedAnswer)
                selected_area_id = execution.get("selectedAreaId")
                if selected_area_id:
                    selected_label = self._official_area_label(execution)
                    answer_folded = candidate.answer.casefold()
                    if selected_label.casefold() not in answer_folded:
                        raise ValueError(f"Narasi tidak menyebut label area resmi {selected_label}")
                    if str(selected_area_id).casefold() in answer_folded:
                        raise ValueError("Narasi mengekspos selectedAreaId internal")
                    foreign_ids = [
                        area_id for area_id in self.area_by_id
                        if area_id != str(selected_area_id) and area_id.casefold() in answer_folded
                    ]
                    if foreign_ids:
                        raise ValueError(f"Narasi menyebut area lain: {foreign_ids[0]}")
                deterministic_fallback = False
                if selected_area_id and len(candidate.answer.strip()) < 40:
                    candidate = candidate.model_copy(
                        update={"answer": self._official_area_summary(execution)}
                    )
                    deterministic_fallback = True
                return candidate, {
                    "attempts": attempt + 1,
                    "durationMs": float(response["total_duration"]) / 1_000_000.0 if response.get("total_duration") is not None else None,
                    "promptEvalCount": response.get("prompt_eval_count"),
                    "evalCount": response.get("eval_count"),
                    "deterministicShortAnswerFallback": deterministic_fallback,
                }
            except (ConnectionError, RuntimeError, TimeoutError, ValidationError, ValueError, json.JSONDecodeError, AssertionError) as error:
                last_error = str(error)
        if execution.get("selectedAreaId"):
            fallback = f"Hasil analisis memilih {self._official_area_label(execution)} berdasarkan rencana analitik tervalidasi."
        elif execution.get("status") == "no_candidates":
            fallback = "Tidak ada kandidat yang memenuhi rencana analitik pada data aktif."
        else:
            fallback = "Model narrator tidak menghasilkan jawaban terstruktur yang valid."
        return NarratedAnswer(answer=fallback, limitations=[last_error], requiredData=list(execution.get("requiredData") or [])), {"attempts": 2, "error": last_error}

    def _official_area_label(self, execution: dict[str, Any]) -> str:
        area_id = str(execution.get("selectedAreaId") or "")
        area = self.area_by_id.get(area_id) or {}
        return str(area.get("label") or "area terpilih")

    def _official_area_summary(self, execution: dict[str, Any]) -> str:
        area_label = self._official_area_label(execution)
        rows = list(execution.get("rows") or [])
        row = rows[0] if rows else {}
        metric_spec = next(iter(execution.get("metrics") or []), {})
        metric_field = str(metric_spec.get("field") or "metrik utama")
        metric_value = row.get(metric_field)
        if isinstance(metric_value, (int, float)):
            metric_text = f"{metric_field} {float(metric_value):.3g}"
        else:
            metric_text = metric_field
        population = int(execution.get("populationCount") or 0)
        kind = str(row.get("kind") or "area kandidat")
        answer = (
            f"Area terpilih adalah {area_label}. Di antara {population} {kind} yang dibandingkan, "
            f"area ini menjadi hasil ranking berdasarkan {metric_text}."
        )
        return answer

    def ask(self, question: str, show: bool = True) -> dict[str, Any]:
        if not question.strip():
            raise ValueError("Pertanyaan tidak boleh kosong.")
        started = time.perf_counter()
        context_run_ids = [str((item.get("artifacts") or {}).get("runId")) for item in self.history[-6:] if (item.get("artifacts") or {}).get("runId")]
        try:
            plan, thinking, thinking_audit, semantic_hints = self.plan_question(question)
            execution = self.executor.execute(plan)
            evidence = self.retrieve(question, execution)
            narrated, narration_usage = self.narrate(question, plan, execution, evidence)
        except (ConnectionError, RuntimeError, TimeoutError, ValidationError, ValueError) as error:
            plan = QueryPlan(
                mode="general_knowledge",
                interpretation="Planner tidak tersedia.",
                assumption="Tidak ada asumsi analitik yang dieksekusi.",
                operation="describe",
                entityKinds=[],
                confidence=0.0,
                unavailableData=[str(error)],
            )
            thinking = str(error)
            thinking_audit = {"status": "failed", "attempts": [], "truncated": False, "error": str(error)}
            execution = {"status": "not_executed", "dataGrounding": "general_knowledge", "selectedAreaId": None, "populationCount": 0, "limitations": [str(error)], "requiredData": []}
            semantic_hints = []
            evidence = []
            narrated = NarratedAnswer(answer="Pipeline reasoning tidak dapat menyelesaikan pertanyaan ini karena planner gagal.", limitations=[str(error)], requiredData=[])
            narration_usage = {"attempts": 0, "error": str(error)}

        selected_area_id = execution.get("selectedAreaId")
        selected = self.area_by_id.get(str(selected_area_id)) if selected_area_id else None
        grounding = str(execution.get("dataGrounding") or "grounded")
        if grounding == "general_knowledge":
            support_level = "unsupported"
        elif execution.get("status") != "ok":
            support_level = "partially_supported"
        elif grounding == "hybrid" or (selected and selected.get("kind") in {"low_flow_area", "low_presence_area"}):
            support_level = "partially_supported"
        else:
            support_level = "supported"
        limitations = list(dict.fromkeys([*(execution.get("limitations") or []), *narrated.limitations]))
        required_data = list(dict.fromkeys([*(execution.get("requiredData") or []), *narrated.requiredData]))
        final = {
            "schemaVersion": "2.0",
            "pipelineVersion": "causal-query-plan-v1",
            "jobId": self.package.job_id,
            "sessionId": self.session_id,
            "contextRunIds": context_run_ids,
            "question": question,
            "supportLevel": support_level,
            "dataGrounding": grounding,
            "interpretation": plan.interpretation,
            "assumption": plan.assumption,
            "alternativeInterpretations": plan.alternativeInterpretations,
            "answer": narrated.answer,
            "selectedAreaId": selected_area_id,
            "selectedArea": selected,
            "evidenceCardIds": [card["cardId"] for card in evidence],
            "limitations": limitations,
            "requiredData": required_data,
            "queryPlan": plan.model_dump(),
            "thinkingAudit": thinking_audit,
            "coordinateSystem": self.package.manifest["coordinateSystem"],
            "provenance": {
                "packagePath": str(self.package.path),
                "packageSchemaVersion": self.package.manifest["schemaVersion"],
                "chatModel": self.config.chat_model,
                "embeddingModel": self.config.embed_model,
                "areaSelectionAuthority": "query_executor",
            },
            "usage": {
                "narration": narration_usage,
                "pipelineLatencyMs": (time.perf_counter() - started) * 1000.0,
            },
        }
        retrieval_audit = {
            "semanticHints": semantic_hints,
            "selectionReason": "Qwen QueryPlan -> validated complete-population executor -> semantic evidence",
            "cards": evidence,
        }
        run_dir = self._save_run(final, retrieval_audit, thinking, plan.model_dump(), execution)
        final["artifacts"] = {
            "runId": run_dir.name,
            "runDirectory": str(run_dir),
            "response": str(run_dir / "response.json"),
            "retrievedEvidence": str(run_dir / "retrieved_evidence.json"),
            "thinkingAudit": str(run_dir / "thinking.txt"),
            "queryPlan": str(run_dir / "query_plan.json"),
            "executionResult": str(run_dir / "execution_result.json"),
        }
        overlay = None
        try:
            overlay = self._render_overlay(run_dir, final)
        except Exception as error:
            # Rendering adalah artefak tambahan. Jawaban teks yang sudah selesai
            # tidak boleh berubah menjadi HTTP 503 hanya karena renderer gagal.
            final["limitations"] = list(dict.fromkeys([
                *final["limitations"],
                f"Overlay floorplan tidak dapat dibuat: {error}",
            ]))
        final["artifacts"]["floorplanOverlay"] = str(overlay) if overlay else None
        _write_json(run_dir / "response.json", final)
        (run_dir / "answer.md").write_text(final["answer"] + "\n", encoding="utf-8")
        files = sorted(path.name for path in run_dir.iterdir())
        _write_json(run_dir / "run_manifest.json", {
            "schemaVersion": "2.0",
            "pipelineVersion": final["pipelineVersion"],
            "runId": run_dir.name,
            "jobId": self.package.job_id,
            "sessionId": self.session_id,
            "contextRunIds": context_run_ids,
            "models": {
                "planner": self.config.chat_model,
                "narrator": self.config.chat_model,
                "embedding": self.config.embed_model,
            },
            "configuration": {
                "numCtx": self.config.num_ctx,
                "plannerTokenBudget": self.config.thinking_num_predict,
                "plannerRetryTokenBudget": self.config.thinking_retry_num_predict,
                "narratorTokenBudget": self.config.answer_num_predict,
                "semanticTopK": self.config.top_k,
                "maximumPlannerRetries": 1,
                "plannerThinkingMode": self.config.planner_thinking_mode,
            },
            "thinkingAudit": thinking_audit,
            "usageAndLatency": final["usage"],
            "files": sorted(set(files + ["run_manifest.json"])),
        })
        latest = run_dir.parent / "latest.json" if self.run_root else run_dir.parent.parent / "latest.json"
        temporary = latest.with_suffix(".tmp")
        _write_json(temporary, {"runId": run_dir.name, "runDirectory": str(run_dir), "response": str(run_dir / "response.json"), "floorplanOverlay": str(overlay) if overlay else None})
        temporary.replace(latest)
        self.history.append(final)
        if show:
            self.display_result(final, evidence, thinking, plan.model_dump(), execution)
        return final

    def _save_run(self, final: dict[str, Any], retrieval_audit: dict[str, Any], thinking: str, query_plan: dict[str, Any], execution: dict[str, Any]) -> Path:
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        query_hash = hashlib.sha256(final["question"].encode()).hexdigest()[:8]
        runs = self.run_root or (self.config.output_root / self.package.job_id / "llm-rag-v2" / "runs")
        target = runs / f"{timestamp}-{query_hash}"
        staging = runs.parent / f".run.{uuid.uuid4().hex}.build"
        staging.mkdir(parents=True, exist_ok=False)
        try:
            _write_json(staging / "response.json", final)
            _write_json(staging / "retrieved_evidence.json", retrieval_audit)
            _write_json(staging / "query_plan.json", query_plan)
            _write_json(staging / "execution_result.json", execution)
            (staging / "thinking.txt").write_text(thinking, encoding="utf-8")
            (staging / "answer.md").write_text(final["answer"] + "\n", encoding="utf-8")
            target.parent.mkdir(parents=True, exist_ok=True)
            staging.rename(target)
        except Exception:
            if staging.exists(): shutil.rmtree(staging)
            raise
        return target

    def _history_roots(self) -> list[tuple[Path, bool]]:
        if self.run_root:
            return [(self.run_root, False)]
        base = self.config.output_root / self.package.job_id
        return [(base / "llm-rag-v2" / "runs", False), (base / "llm-rag-v1" / "runs", True)]

    def saved_runs(self, limit: int = 100) -> list[dict[str, Any]]:
        entries: list[dict[str, Any]] = []
        for root, legacy in self._history_roots():
            if not root.is_dir(): continue
            for run_dir in (path for path in root.iterdir() if path.is_dir()):
                response_path = run_dir / "response.json"
                if not response_path.is_file(): continue
                try: response = _read_json(response_path)
                except (OSError, json.JSONDecodeError): continue
                entries.append({
                    "runId": run_dir.name,
                    "runDirectory": str(run_dir),
                    "question": str(response.get("question") or "(pertanyaan tidak tersedia)"),
                    "supportLevel": str(response.get("supportLevel") or "unknown"),
                    "dataGrounding": str(response.get("dataGrounding") or "legacy"),
                    "legacy": legacy or not (run_dir / "query_plan.json").is_file(),
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
        audit = _read_json(run_dir / "retrieved_evidence.json") if (run_dir / "retrieved_evidence.json").is_file() else {}
        thinking = (run_dir / "thinking.txt").read_text(encoding="utf-8") if (run_dir / "thinking.txt").is_file() else ""
        query_plan = _read_json(run_dir / "query_plan.json") if (run_dir / "query_plan.json").is_file() else None
        execution = _read_json(run_dir / "execution_result.json") if (run_dir / "execution_result.json").is_file() else None
        return {"response": response, "evidence": list(audit.get("cards") or []), "thinking": thinking, "queryPlan": query_plan, "execution": execution, "legacy": query_plan is None}

    def load_saved_run(self, run_id: str) -> tuple[dict[str, Any], list[dict[str, Any]], str]:
        matches = [entry for entry in self.saved_runs(limit=1000) if entry["runId"] == run_id]
        if not matches: raise FileNotFoundError(f"Riwayat run tidak ditemukan: {run_id}")
        bundle = self.load_saved_bundle(matches[0]["runDirectory"])
        return bundle["response"], bundle["evidence"], bundle["thinking"]

    def _validate_official_geometry(self, area: dict[str, Any]) -> None:
        geometry = area.get("geometryM") or {}
        kind = geometry.get("type")
        coordinate = self.package.manifest["coordinateSystem"]
        venue = box(0, 0, float(coordinate["widthM"]), float(coordinate["heightM"]))
        if kind == "polygon": shape = Polygon(geometry.get("points") or [], geometry.get("holes") or None)
        elif kind == "circle":
            radius = float(geometry.get("radiusM", 0)); shape = Point(*geometry["center"]).buffer(radius, quad_segs=48)
            if radius <= 0: raise ValueError(f"Radius area tidak valid: {area.get('areaId')}")
        elif kind == "ellipse":
            radii = np.asarray(geometry.get("radiiM"), dtype=float); center = np.asarray(geometry.get("center"), dtype=float)
            if radii.shape != (2,) or center.shape != (2,) or np.any(radii <= 0): raise ValueError(f"Ellipse area tidak valid: {area.get('areaId')}")
            angles = np.linspace(0, 2 * np.pi, 97); points = np.c_[radii[0] * np.cos(angles), radii[1] * np.sin(angles)]
            theta = np.radians(float(geometry.get("angleDeg", 0))); rotation = np.array([[np.cos(theta), -np.sin(theta)], [np.sin(theta), np.cos(theta)]])
            shape = Polygon(points @ rotation.T + center)
        elif kind == "polyline": shape = LineString(geometry.get("points") or [])
        else: raise ValueError(f"Geometry area tidak didukung: {area.get('areaId')} ({kind})")
        bounds = np.asarray(shape.bounds, dtype=float)
        if not shape.is_valid or shape.is_empty or bounds.shape != (4,) or not np.all(np.isfinite(bounds)) or shape.intersection(venue).is_empty:
            raise ValueError(f"Geometry resmi invalid atau tidak beririsan dengan venue: {area.get('areaId')}")

    def _render_overlay(self, run_dir: Path, final: dict[str, Any]) -> Path | None:
        area = final.get("selectedArea")
        if not area or final["dataGrounding"] == "general_knowledge": return None
        floorplan_value = self.package.manifest.get("floorplan", {}).get("sourcePath")
        coordinate = self.package.manifest["coordinateSystem"]; width, height = float(coordinate["widthM"]), float(coordinate["heightM"])
        color = "#f4a261" if final["supportLevel"] == "partially_supported" else "#0077b6"
        figure, axis = plt.subplots(figsize=(11, 8))
        floorplan = Path(floorplan_value).expanduser() if floorplan_value else None
        if floorplan and floorplan.is_file():
            axis.imshow(plt.imread(floorplan), origin="upper", extent=(0, width, height, 0), aspect="equal")
        else:
            axis.set_facecolor("#f6f7f9")
            axis.set_xticks(np.arange(0, width + 0.001, max(0.5, width / 10)), minor=True)
            axis.set_yticks(np.arange(0, height + 0.001, max(0.5, height / 10)), minor=True)
            axis.grid(which="minor", color="#c7ccd4", alpha=0.45, linewidth=0.7)
        self._draw_geometry(axis, area["geometryM"], color, area["areaId"])
        if area.get("interactionGeometryM"): self._draw_geometry(axis, area["interactionGeometryM"], "#2a9d8f", "interaction zone", alpha=0.12, dashed=True)
        metric_items = list((area.get("metrics") or {}).items())[:5]
        metric_text = "\n".join(f"{key}: {value:.3g}" if isinstance(value, (float, int)) else f"{key}: {value}" for key, value in metric_items)
        axis.text(1.02, 0.98, f"{area['areaId']}\nconfidence: {area.get('confidence', 0):.2f}\n{metric_text}", transform=axis.transAxes, va="top", fontsize=9, bbox={"boxstyle": "round", "facecolor": "white", "alpha": 0.92})
        axis.set(xlim=(0, width), ylim=(height, 0), aspect="equal", xlabel="x (m)", ylabel="y (m)", title=f"Area terpilih — {final['dataGrounding']}")
        figure.subplots_adjust(right=0.78); target = run_dir / "floorplan_overlay.png"; figure.savefig(target, dpi=180, bbox_inches="tight"); plt.close(figure); return target

    @staticmethod
    def _draw_geometry(axis: Any, geometry: dict[str, Any], color: str, label: str, alpha: float = 0.28, dashed: bool = False) -> None:
        style = "--" if dashed else "-"; kind = geometry.get("type")
        if kind == "polygon":
            patch = MplPolygon(np.asarray(geometry["points"]), closed=True, facecolor=color, edgecolor=color, linewidth=3, linestyle=style, alpha=alpha); axis.add_patch(patch); patch.set_clip_path(axis.patch); center = geometry.get("centroid") or np.asarray(geometry["points"]).mean(axis=0)
        elif kind == "circle":
            center = geometry["center"]; patch = plt.Circle(center, geometry["radiusM"], facecolor=color, edgecolor=color, linewidth=3, linestyle=style, alpha=alpha); axis.add_patch(patch); patch.set_clip_path(axis.patch)
        elif kind == "ellipse":
            center = geometry["center"]; patch = Ellipse(center, 2 * geometry["radiiM"][0], 2 * geometry["radiiM"][1], angle=geometry.get("angleDeg", 0), facecolor=color, edgecolor=color, linewidth=3, linestyle=style, alpha=alpha); axis.add_patch(patch); patch.set_clip_path(axis.patch)
        elif kind == "polyline":
            points = np.asarray(geometry["points"]); axis.plot(points[:, 0], points[:, 1], color=color, linewidth=4, linestyle=style); center = points[len(points) // 2]
        else: raise ValueError(f"Geometry overlay tidak didukung: {kind}")
        axis.scatter([center[0]], [center[1]], marker="x", s=70, linewidths=2, color=color); axis.text(center[0], center[1], label, ha="center", va="bottom", color="white", fontsize=9, bbox={"boxstyle": "round", "facecolor": color, "alpha": 0.95})

    @staticmethod
    def display_result(final: dict[str, Any], evidence: list[dict[str, Any]], thinking: str, query_plan: dict[str, Any] | None = None, execution: dict[str, Any] | None = None, legacy: bool = False) -> None:
        try:
            from IPython.display import HTML, Markdown, display
        except ImportError as error:
            raise RuntimeError("display_result hanya tersedia di runtime notebook/IPython") from error
        audit = final.get("thinkingAudit") or {}; state = str(audit.get("status") or ("legacy" if legacy else "unknown"))
        if thinking:
            display(HTML("<details open><summary><b>Raw thinking</b> — " + html.escape(state) + "</summary><pre style='white-space:pre-wrap;max-height:34rem;overflow:auto;padding:12px;background:#f6f8fa;border:1px solid #d0d7de;border-radius:6px'>" + html.escape(thinking) + "</pre></details>"))
        elif not legacy:
            display(HTML("<div style='padding:8px 10px;background:#eef6ff;border-left:4px solid #0077b6'><b>Planner compact</b> — raw thinking dinonaktifkan; QueryPlan tervalidasi di bawah adalah audit keputusan yang dieksekusi. Thinking mendalam akan aktif otomatis jika plan awal invalid.</div>"))
        if legacy: display(HTML("<span style='background:#6c757d;color:white;padding:4px 9px;border-radius:8px'>legacy pipeline</span>"))
        if query_plan:
            display(Markdown("### Interpretasi\n\n" + str(query_plan.get("interpretation") or "—") + "\n\n**Asumsi:** " + str(query_plan.get("assumption") or "—")))
            display(HTML("<details><summary>QueryPlan tervalidasi</summary><pre style='white-space:pre-wrap'>" + html.escape(json.dumps(query_plan, ensure_ascii=False, indent=2)) + "</pre></details>"))
        if execution:
            display(Markdown("### Hasil executor"))
            summary = {key: execution.get(key) for key in ("status", "dataGrounding", "dataset", "operation", "populationCount", "selectedAreaId") if key in execution}
            display(pd.DataFrame([summary]))
            if execution.get("rows"): display(pd.DataFrame(execution["rows"]))
        badge_color = {"supported": "#2a9d8f", "partially_supported": "#f4a261", "unsupported": "#d62828"}.get(final.get("supportLevel"), "#6c757d")
        display(HTML(f"<span style='background:{badge_color};color:white;padding:4px 9px;border-radius:8px'>{html.escape(str(final.get('supportLevel')))}</span> <b>{html.escape(str(final.get('dataGrounding') or 'legacy'))}</b>"))
        if evidence:
            display(Markdown("### Evidence")); display(pd.DataFrame([{"cardId": card.get("cardId"), "score": round(float(card.get("retrievalScore", 0.0)), 4), "areaId": card.get("areaId"), "statement": card.get("statement")} for card in evidence]))
        display(Markdown("### Jawaban\n\n" + str(final.get("answer") or "")))
        overlay = (final.get("artifacts") or {}).get("floorplanOverlay")
        if overlay and Path(overlay).is_file():
            from IPython.display import Image
            display(Image(filename=Path(overlay).as_posix()))

    def widget(self):
        import ipywidgets as widgets
        question = widgets.Textarea(value="Area mana yang paling sering dilewati?", placeholder="Tulis pertanyaan atau follow-up...", description="Pertanyaan", layout=widgets.Layout(width="100%", height="90px"))
        ask_button = widgets.Button(description="Ask Qwen3", button_style="primary", icon="search"); clear_button = widgets.Button(description="Clear"); new_session_button = widgets.Button(description="Sesi baru", icon="plus")
        status = widgets.HTML(value=f"<b>Job:</b> {self.package.job_id} &nbsp; <b>Model:</b> {self.config.chat_model} &nbsp; <b>Session:</b> {self.session_id}"); output = widgets.Output()
        history_picker = widgets.Dropdown(description="Run", options=[], layout=widgets.Layout(width="100%")); refresh_history_button = widgets.Button(description="Refresh riwayat", icon="refresh"); load_history_button = widgets.Button(description="Buka run", button_style="info", icon="folder-open"); history_status = widgets.HTML(); history_lookup: dict[str, dict[str, Any]] = {}

        def refresh_history(_: Any = None) -> None:
            nonlocal history_lookup
            entries = self.saved_runs(); history_lookup = {entry["runId"]: entry for entry in entries}
            history_picker.options = [(f"{'LEGACY · ' if entry['legacy'] else ''}{entry['runId']} · {entry['supportLevel']} · {entry['question'][:72]}", entry["runId"]) for entry in entries]
            history_status.value = f"{len(entries)} run tersimpan untuk job {self.package.job_id}."

        def load_history(_: Any) -> None:
            run_id = history_picker.value
            if not run_id: history_status.value = "Pilih run terlebih dahulu."; return
            with output:
                output.clear_output(wait=True)
                try:
                    entry = history_lookup[str(run_id)]; bundle = self.load_saved_bundle(entry["runDirectory"])
                    self.display_result(bundle["response"], bundle["evidence"], bundle["thinking"], bundle["queryPlan"], bundle["execution"], bundle["legacy"]); history_status.value = f"Menampilkan {run_id}."
                except Exception as error: display(HTML(f"<div style='color:#b00020'><b>Error riwayat:</b> {html.escape(str(error))}</div>")); history_status.value = "Gagal membuka run."

        def ask_clicked(_: Any) -> None:
            ask_button.disabled = True; status.value = "Planner Qwen3 sedang reasoning, lalu executor menghitung hasil..."
            with output:
                output.clear_output(wait=True)
                try:
                    self.ask(question.value, show=True); refresh_history(); status.value = f"Selesai · session {self.session_id} · {len(self.history)} turn aktif · {len(history_lookup)} run tersimpan."
                except Exception as error: display(HTML(f"<div style='color:#b00020'><b>Error:</b> {html.escape(str(error))}</div>")); status.value = "Gagal; lihat detail error."
                finally: ask_button.disabled = False

        def new_session(_: Any) -> None:
            session_id = self.new_session(); status.value = f"Sesi baru: {session_id}. Riwayat tersimpan tidak dihapus."; question.value = ""

        ask_button.on_click(ask_clicked); clear_button.on_click(lambda _: output.clear_output()); new_session_button.on_click(new_session); refresh_history_button.on_click(refresh_history); load_history_button.on_click(load_history); refresh_history()
        history_panel = widgets.VBox([widgets.HTML("<b>Riwayat tersimpan</b> — run lama dapat dibuka tetapi tidak otomatis masuk konteks sesi."), widgets.HBox([refresh_history_button, load_history_button]), history_picker, history_status])
        details = widgets.Accordion(children=[history_panel]); details.set_title(0, "Riwayat jawaban")
        return widgets.VBox([status, question, widgets.HBox([ask_button, clear_button, new_session_button]), details, output])
