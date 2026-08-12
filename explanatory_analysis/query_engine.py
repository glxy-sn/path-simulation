from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

import numpy as np
import pandas as pd
import pyarrow.parquet as pq
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


PlanMode = Literal["analytical", "descriptive", "recommendation", "hybrid", "general_knowledge"]
Operation = Literal["rank", "lookup", "aggregate", "compare", "trend", "describe", "recommend"]
Aggregation = Literal["value", "count", "sum", "mean", "median", "p95", "min", "max"]
Direction = Literal["min", "max", "none"]
FilterOperator = Literal["eq", "ne", "lt", "lte", "gt", "gte", "in"]


class MetricExpression(BaseModel):
    model_config = ConfigDict(extra="forbid")

    field: str
    aggregation: Aggregation = "value"
    direction: Direction = "none"
    weight: float = Field(default=1.0, ge=0.0, le=10.0)


class QueryFilter(BaseModel):
    model_config = ConfigDict(extra="forbid")

    field: str
    operator: FilterOperator
    value: str | int | float | bool | list[str] | list[int] | list[float]


class TimeRange(BaseModel):
    model_config = ConfigDict(extra="forbid")

    startSec: float | None = Field(default=None, ge=0)
    endSec: float | None = Field(default=None, ge=0)

    @model_validator(mode="after")
    def validate_order(self) -> "TimeRange":
        if self.startSec is not None and self.endSec is not None and self.endSec < self.startSec:
            raise ValueError("endSec harus lebih besar atau sama dengan startSec")
        return self


class QueryPlan(BaseModel):
    """Safe analytical plan emitted by the reasoning model.

    The schema is intentionally generic: it describes datasets, fields and
    operators instead of enumerating natural-language intents.
    """

    model_config = ConfigDict(extra="forbid")

    schemaVersion: Literal["1.0"] = "1.0"
    mode: PlanMode
    interpretation: str
    assumption: str
    alternativeInterpretations: list[str] = Field(default_factory=list, max_length=5)
    dataset: str | None = None
    operation: Operation
    entityKinds: list[str]
    areaIds: list[str] = Field(default_factory=list)
    metrics: list[MetricExpression] = Field(default_factory=list, max_length=6)
    filters: list[QueryFilter] = Field(default_factory=list, max_length=12)
    timeRange: TimeRange | None = None
    spatialAnswer: bool = False
    confidence: float = Field(ge=0.0, le=1.0)
    unavailableData: list[str] = Field(default_factory=list)

    @field_validator("dataset")
    @classmethod
    def normalize_dataset(cls, value: str | None) -> str | None:
        return value.strip() if isinstance(value, str) and value.strip() else None

    @model_validator(mode="after")
    def validate_mode_shape(self) -> "QueryPlan":
        if self.mode == "general_knowledge":
            if self.dataset or self.entityKinds or self.areaIds or self.metrics or self.filters or self.timeRange or self.spatialAnswer:
                raise ValueError("general_knowledge tidak boleh membawa dataset, filter, metrik, time range, atau spatial answer")
            return self
        if self.mode in {"analytical", "recommendation", "hybrid"} and not self.dataset:
            raise ValueError("Mode berbasis data harus memilih dataset")
        if self.operation in {"rank", "aggregate", "compare", "trend", "recommend"} and self.mode != "general_knowledge" and not self.metrics:
            raise ValueError("Operasi analitik harus memiliki metrik")
        if self.mode != "general_knowledge" and self.operation in {"rank", "recommend"} and all(metric.direction == "none" for metric in self.metrics):
            raise ValueError("Ranking/recommendation memerlukan arah min atau max")
        return self


class NarratedAnswer(BaseModel):
    model_config = ConfigDict(extra="forbid")

    answer: str
    limitations: list[str]
    requiredData: list[str]


@dataclass(frozen=True)
class DatasetSpec:
    name: str
    description: str
    fields: dict[str, str]
    row_count: int
    spatial: bool = False


FIELD_DESCRIPTIONS: dict[str, str] = {
    "areaId": "ID area resmi yang geometry-nya disimpan dalam spatial_areas.json",
    "kind": "jenis area observasional",
    "confidence": "confidence area 0 sampai 1",
    "relativeIntensity": "intensitas relatif terhadap area terkuat dari jenis yang sama",
    "observedPresenceSec": "total detik kehadiran valid dalam area",
    "totalPathLengthM": "total panjang lintasan valid di area dalam meter",
    "meanSpeedMps": "kecepatan rata-rata meter per detik",
    "uniqueVisitors": "jumlah anonymous global track unik",
    "visitCount": "jumlah episode kunjungan",
    "meanVisitDurationSec": "durasi kunjungan rata-rata dalam detik",
    "medianVisitDurationSec": "median durasi kunjungan dalam detik",
    "p95VisitDurationSec": "persentil ke-95 durasi kunjungan dalam detik",
    "totalDwellSec": "total durasi berhenti dalam detik",
    "medianEpisodeSec": "median durasi episode berhenti",
    "peakConcurrentTracks": "jumlah track bersamaan tertinggi",
    "observedCrowdedSeconds": "total detik area memenuhi kondisi crowd",
    "supportTracks": "jumlah track pendukung route",
    "supportJobs": "jumlah job venue-compatible pendukung route",
    "usualAcrossJobs": "apakah route didukung lintas job",
    "tableAreaM2": "luas polygon permukaan meja",
    "interactionAreaM2": "luas interaction zone meja",
    "zoneAreaM2": "luas zona manual dalam meter persegi",
    "count": "jumlah anonymous track pada bin waktu",
    "binStartSec": "awal bin waktu relatif dalam detik",
    "binEndSec": "akhir bin waktu relatif dalam detik",
    "durationSec": "durasi episode dalam detik",
    "pathLengthM": "panjang lintasan track dalam meter",
    "stopDurationSec": "total durasi berhenti track",
    "groupSize": "jumlah track pada episode co-moving",
    "soloObservationRatio": "rasio observasi yang tidak masuk episode co-moving",
}


DATASET_DESCRIPTIONS: dict[str, str] = {
    "spatial_areas": "Area dinamis dan annotation meja. Gunakan ini untuk pertanyaan yang harus mengembalikan area/overlay.",
    "occupancy_timeseries": "Jumlah anonymous track unik per bin waktu 10 detik.",
    "area_visits": "Episode masuk/keluar setiap dynamic area per track.",
    "table_usage": "Episode interaksi track dengan meja teranotasi.",
    "track_summary": "Ringkasan durasi, panjang jalur, speed, stop dan kualitas per track.",
    "stop_episodes": "Episode berhenti individual dan centroid-nya.",
    "group_episodes": "Episode co-moving proxy; bukan hubungan sosial.",
    "crowd_bottleneck_timeseries": "Occupancy lokal, speed ratio, crowded, bottleneck dan queue-like per waktu/cell.",
    "spatial_density_surface": "Continuous presence/flow density per 0.05 m cell, dengan observed-support confidence; bukan walkable-floor mask.",
    "trajectory_enriched": "Titik trajectory valid/enriched. Pakai hanya jika dataset agregat tidak cukup.",
    "summary": "Ringkasan job, occupancy, dwell, movement, group, table dan QC.",
}


AREA_KIND_DESCRIPTIONS: dict[str, str] = {
    "presence_hotspot": "Konsentrasi kehadiran; dapat dibandingkan min/max hanya di antara hotspot presence yang terdeteksi.",
    "flow_hotspot": "Konsentrasi pergerakan; relativeIntensity min berarti paling rendah di antara hotspot flow yang terdeteksi.",
    "low_presence_area": "Kandidat kehadiran rendah di observed-support envelope; bukan seluruh walkable floor.",
    "low_flow_area": "Kandidat flow rendah di observed-support envelope; bukan seluruh walkable floor.",
    "crowd_zone": "Area dengan occupancy lokal bersamaan tinggi.",
    "stop_cluster": "Cluster lokasi episode berhenti.",
    "bottleneck_area": "Area bottleneck observasional dari density, speed drop dan persistence.",
    "route_archetype": "Polyline pola lintasan yang didukung beberapa track.",
    "table": "Polygon meja manual dan interaction zone terhitung.",
    "custom_zone": "Rectangle area bernama yang dibuat pengguna pada denah.",
}


class DataCatalog:
    def __init__(self, package_path: Path, areas: list[dict[str, Any]], summary: dict[str, Any]):
        self.package_path = package_path
        self.areas = areas
        self.summary = summary
        self._frames: dict[str, pd.DataFrame] = {}
        self.specs = self._build_specs()

    @staticmethod
    def _safe_scalar(value: Any) -> Any:
        if isinstance(value, (np.integer,)):
            return int(value)
        if isinstance(value, (np.floating, float)):
            value = float(value)
            return value if math.isfinite(value) else None
        if isinstance(value, np.ndarray):
            return value.tolist()
        return value

    def _area_frame(self) -> pd.DataFrame:
        rows: list[dict[str, Any]] = []
        for area in self.areas:
            row = {
                "areaId": area["areaId"],
                "kind": area["kind"],
                "confidence": area.get("confidence"),
                "limitation": area.get("limitation"),
            }
            row.update(area.get("metrics") or {})
            rows.append(row)
        return pd.DataFrame(rows)

    def _summary_frame(self) -> pd.DataFrame:
        flat: dict[str, Any] = {}

        def visit(prefix: str, value: Any) -> None:
            if isinstance(value, dict):
                for key, item in value.items():
                    visit(f"{prefix}.{key}" if prefix else str(key), item)
            elif not isinstance(value, (list, tuple)):
                flat[prefix] = value

        visit("", self.summary)
        return pd.DataFrame([flat])

    def _build_specs(self) -> dict[str, DatasetSpec]:
        specs: dict[str, DatasetSpec] = {}
        area_frame = self._area_frame()
        self._frames["spatial_areas"] = area_frame
        specs["spatial_areas"] = DatasetSpec(
            "spatial_areas",
            DATASET_DESCRIPTIONS["spatial_areas"],
            {column: FIELD_DESCRIPTIONS.get(column, f"Metrik area: {column}") for column in area_frame.columns},
            len(area_frame),
            spatial=True,
        )
        summary_frame = self._summary_frame()
        self._frames["summary"] = summary_frame
        specs["summary"] = DatasetSpec(
            "summary",
            DATASET_DESCRIPTIONS["summary"],
            {column: FIELD_DESCRIPTIONS.get(column, column) for column in summary_frame.columns},
            1,
        )
        for path in sorted(self.package_path.glob("*.parquet")):
            name = path.stem
            schema = pq.read_schema(path)
            fields = {field.name: FIELD_DESCRIPTIONS.get(field.name, f"Kolom {field.name} ({field.type})") for field in schema}
            specs[name] = DatasetSpec(name, DATASET_DESCRIPTIONS.get(name, f"Tabel analytics {name}."), fields, pq.ParquetFile(path).metadata.num_rows)
        return specs

    def prompt_payload(self, selected_datasets: set[str] | None = None) -> dict[str, Any]:
        selected = selected_datasets or {"spatial_areas"}
        selected = {name for name in selected if name in self.specs} | {"spatial_areas"}
        return {
            "datasetDirectory": [
                {
                    "name": spec.name,
                    "description": spec.description,
                    "rowCount": spec.row_count,
                    "spatial": spec.spatial,
                }
                for spec in self.specs.values()
            ],
            "selectedSchemas": [
                {"name": self.specs[name].name, "fields": self.specs[name].fields}
                for name in sorted(selected)
            ],
            "areaKinds": [
                {"kind": kind, "description": description, "count": sum(area.get("kind") == kind for area in self.areas)}
                for kind, description in AREA_KIND_DESCRIPTIONS.items()
                if any(area.get("kind") == kind for area in self.areas)
            ],
            "operators": {
                "operations": ["rank", "lookup", "aggregate", "compare", "trend", "describe", "recommend"],
                "aggregations": ["value", "count", "sum", "mean", "median", "p95", "min", "max"],
                "directions": ["min", "max", "none"],
                "filters": ["eq", "ne", "lt", "lte", "gt", "gte", "in"],
            },
        }

    def frame(self, name: str) -> pd.DataFrame:
        if name not in self.specs:
            raise ValueError(f"Dataset tidak tersedia: {name}")
        if name not in self._frames:
            path = self.package_path / f"{name}.parquet"
            self._frames[name] = pd.read_parquet(path)
        return self._frames[name].copy()

    def normalize_plan(self, plan: QueryPlan) -> QueryPlan:
        """Canonicalize equivalent structured choices before strict validation.

        This does not interpret natural language. It only moves an explicit,
        catalog-valid ``kind`` filter into ``entityKinds`` and removes a
        redundant area-kind token accidentally emitted as a metric name.
        """
        if plan.dataset != "spatial_areas":
            return plan
        payload = plan.model_dump()
        kinds = list(payload.get("entityKinds") or [])
        for query_filter in payload.get("filters") or []:
            if query_filter.get("field") != "kind" or query_filter.get("operator") not in {"eq", "in"}:
                continue
            values = query_filter.get("value")
            for value in values if isinstance(values, list) else [values]:
                if value in AREA_KIND_DESCRIPTIONS and value not in kinds:
                    kinds.append(value)
        payload["entityKinds"] = kinds
        metrics = payload.get("metrics") or []
        numeric_metrics = [metric for metric in metrics if metric.get("field") not in AREA_KIND_DESCRIPTIONS]
        if numeric_metrics:
            payload["metrics"] = numeric_metrics
        if (
            payload.get("operation") in {"rank", "recommend"}
            and any(metric.get("field") == "relativeIntensity" for metric in payload.get("metrics") or [])
            and len(payload["entityKinds"]) > 1
            and not payload.get("areaIds")
        ):
            primary_kind, *alternative_kinds = payload["entityKinds"]
            payload["entityKinds"] = [primary_kind]
            alternatives = list(payload.get("alternativeInterpretations") or [])
            for kind in alternative_kinds:
                note = f"Ranking alternatif untuk area kind {kind} (tidak dieksekusi)"
                if note not in alternatives:
                    alternatives.append(note)
            payload["alternativeInterpretations"] = alternatives[:5]
        return QueryPlan.model_validate(payload)

    def validate_plan(self, plan: QueryPlan, areas_by_id: dict[str, dict[str, Any]]) -> None:
        if plan.mode == "general_knowledge":
            return
        if not plan.dataset or plan.dataset not in self.specs:
            raise ValueError(f"Dataset planner tidak tersedia: {plan.dataset}")
        fields = self.specs[plan.dataset].fields
        for metric in plan.metrics:
            if metric.field not in fields:
                raise ValueError(f"Metrik {metric.field} tidak ada di dataset {plan.dataset}")
        for query_filter in plan.filters:
            if query_filter.field not in fields:
                raise ValueError(f"Filter field {query_filter.field} tidak ada di dataset {plan.dataset}")
        unknown_kinds = set(plan.entityKinds) - set(AREA_KIND_DESCRIPTIONS)
        if unknown_kinds:
            raise ValueError(f"Area kind tidak dikenal: {sorted(unknown_kinds)}")
        unknown_areas = set(plan.areaIds) - set(areas_by_id)
        if unknown_areas:
            raise ValueError(f"Area ID tidak dikenal: {sorted(unknown_areas)}")
        if plan.dataset == "spatial_areas" and plan.operation in {"rank", "recommend"}:
            if not plan.entityKinds and not plan.areaIds:
                raise ValueError("Ranking area membutuhkan populasi pembanding eksplisit melalui entityKinds atau areaIds")
            relative_metrics = [metric for metric in plan.metrics if metric.field == "relativeIntensity"]
            if relative_metrics:
                compared_kinds = set(plan.entityKinds)
                compared_kinds.update(
                    str(areas_by_id[area_id].get("kind"))
                    for area_id in plan.areaIds
                    if area_id in areas_by_id
                )
                compared_kinds.discard("")
                compared_kinds.discard("None")
                if len(compared_kinds) != 1:
                    raise ValueError(
                        "relativeIntensity hanya dapat diranking dalam tepat satu area kind; "
                        "pilih satu populasi yang metriknya sebanding"
                    )


class QueryExecutor:
    def __init__(self, catalog: DataCatalog, areas_by_id: dict[str, dict[str, Any]]):
        self.catalog = catalog
        self.areas_by_id = areas_by_id

    @staticmethod
    def _json_value(value: Any) -> Any:
        if not isinstance(value, (list, tuple, dict, np.ndarray)) and pd.isna(value):
            return None
        if isinstance(value, np.ndarray):
            return value.tolist()
        if isinstance(value, (np.integer,)):
            return int(value)
        if isinstance(value, (np.floating, float)):
            number = float(value)
            return number if math.isfinite(number) else None
        if isinstance(value, pd.Timestamp):
            return value.isoformat()
        return value

    @classmethod
    def _records(cls, frame: pd.DataFrame, limit: int = 20) -> list[dict[str, Any]]:
        return [{str(key): cls._json_value(value) for key, value in row.items()} for row in frame.head(limit).to_dict(orient="records")]

    @staticmethod
    def _apply_filter(frame: pd.DataFrame, query_filter: QueryFilter) -> pd.DataFrame:
        series = frame[query_filter.field]
        value = query_filter.value
        if query_filter.operator == "eq": mask = series == value
        elif query_filter.operator == "ne": mask = series != value
        elif query_filter.operator == "lt": mask = series < value
        elif query_filter.operator == "lte": mask = series <= value
        elif query_filter.operator == "gt": mask = series > value
        elif query_filter.operator == "gte": mask = series >= value
        elif query_filter.operator == "in": mask = series.isin(value if isinstance(value, list) else [value])
        else: raise ValueError(f"Operator filter tidak didukung: {query_filter.operator}")
        return frame.loc[mask.fillna(False)].copy()

    @staticmethod
    def _aggregate(series: pd.Series, aggregation: Aggregation) -> float | int | None:
        numeric = pd.to_numeric(series, errors="coerce").dropna()
        if aggregation == "count": return int(series.notna().sum())
        if numeric.empty: return None
        if aggregation == "sum": return float(numeric.sum())
        if aggregation == "mean": return float(numeric.mean())
        if aggregation == "median": return float(numeric.median())
        if aggregation == "p95": return float(numeric.quantile(0.95))
        if aggregation == "min": return float(numeric.min())
        if aggregation == "max": return float(numeric.max())
        return float(numeric.iloc[0]) if len(numeric) == 1 else None

    def execute(self, plan: QueryPlan) -> dict[str, Any]:
        if plan.mode == "general_knowledge":
            return {
                "status": "not_executed",
                "dataGrounding": "general_knowledge",
                "selectedAreaId": None,
                "populationCount": 0,
                "limitations": ["Pertanyaan dijawab dari pengetahuan model; tidak didukung data trajectory job aktif."],
                "requiredData": plan.unavailableData,
            }
        frame = self.catalog.frame(str(plan.dataset))
        input_count = len(frame)
        if plan.entityKinds:
            if "kind" not in frame.columns:
                raise ValueError("entityKinds hanya dapat dipakai pada dataset yang memiliki kolom kind")
            frame = frame.loc[frame["kind"].isin(plan.entityKinds)].copy()
        if plan.areaIds:
            if "areaId" not in frame.columns:
                raise ValueError("areaIds hanya dapat dipakai pada dataset yang memiliki kolom areaId")
            frame = frame.loc[frame["areaId"].isin(plan.areaIds)].copy()
        for query_filter in plan.filters:
            frame = self._apply_filter(frame, query_filter)
        if plan.timeRange:
            start = plan.timeRange.startSec
            end = plan.timeRange.endSec
            start_field = next((field for field in ("binStartSec", "startSec", "timeSec", "t") if field in frame.columns), None)
            end_field = next((field for field in ("binEndSec", "endSec", "timeSec", "t") if field in frame.columns), start_field)
            if not start_field:
                raise ValueError(f"Dataset {plan.dataset} tidak memiliki field waktu")
            if start is not None: frame = frame.loc[pd.to_numeric(frame[end_field], errors="coerce") >= start].copy()
            if end is not None: frame = frame.loc[pd.to_numeric(frame[start_field], errors="coerce") <= end].copy()
        if frame.empty:
            return {
                "status": "no_candidates",
                "dataGrounding": "grounded",
                "dataset": plan.dataset,
                "selectedAreaId": None,
                "inputPopulationCount": input_count,
                "populationCount": 0,
                "rows": [],
                "limitations": ["Tidak ada kandidat yang memenuhi QueryPlan pada data aktif."],
                "requiredData": plan.unavailableData,
            }

        selected_area_id: str | None = None
        metric_results: list[dict[str, Any]] = []
        ranked = frame.copy()
        if plan.operation in {"rank", "recommend"}:
            score = pd.Series(0.0, index=ranked.index)
            total_weight = sum(metric.weight for metric in plan.metrics if metric.direction != "none") or 1.0
            for metric in plan.metrics:
                values = pd.to_numeric(ranked[metric.field], errors="coerce")
                valid = values.dropna()
                if valid.empty:
                    raise ValueError(f"Metrik ranking bukan numeric atau seluruhnya kosong: {metric.field}")
                low, high = float(valid.min()), float(valid.max())
                normalized = pd.Series(0.5, index=ranked.index)
                if high > low:
                    normalized = (values - low) / (high - low)
                if metric.direction == "min": normalized = 1.0 - normalized
                if metric.direction != "none": score = score + normalized.fillna(0.0) * (metric.weight / total_weight)
                metric_results.append({"field": metric.field, "direction": metric.direction, "weight": metric.weight, "min": low, "max": high})
            ranked["computedScore"] = score
            tie_fields = [metric.field for metric in plan.metrics]
            ranked = ranked.sort_values(["computedScore", *tie_fields], ascending=[False] + [metric.direction == "min" for metric in plan.metrics], kind="stable")
            if "areaId" in ranked.columns:
                selected_area_id = str(ranked.iloc[0]["areaId"])
        elif plan.operation == "aggregate":
            aggregates = [
                {"field": metric.field, "aggregation": metric.aggregation, "value": self._aggregate(frame[metric.field], metric.aggregation)}
                for metric in plan.metrics
            ]
            metric_results = aggregates
        elif plan.operation == "trend":
            time_field = next((field for field in ("binStartSec", "startSec", "timeSec", "t") if field in frame.columns), None)
            if time_field: ranked = ranked.sort_values(time_field, kind="stable")
            metric_results = [
                {"field": metric.field, "aggregation": metric.aggregation, "value": self._aggregate(frame[metric.field], metric.aggregation)}
                for metric in plan.metrics
            ]
        elif plan.operation in {"lookup", "compare", "describe"}:
            if "areaId" in ranked.columns and len(ranked) == 1:
                selected_area_id = str(ranked.iloc[0]["areaId"])
            metric_results = [
                {"field": metric.field, "aggregation": metric.aggregation, "value": self._aggregate(frame[metric.field], metric.aggregation)}
                for metric in plan.metrics
            ]

        limitations = list(plan.unavailableData)
        if selected_area_id:
            limitation = self.areas_by_id[selected_area_id].get("limitation")
            if limitation: limitations.append(str(limitation))
        grounding = "hybrid" if plan.mode == "hybrid" else "grounded"
        return {
            "status": "ok",
            "dataGrounding": grounding,
            "dataset": plan.dataset,
            "operation": plan.operation,
            "selectedAreaId": selected_area_id,
            "inputPopulationCount": input_count,
            "populationCount": len(frame),
            "metrics": metric_results,
            "rows": self._records(ranked),
            "limitations": list(dict.fromkeys(limitations)),
            "requiredData": plan.unavailableData,
        }
