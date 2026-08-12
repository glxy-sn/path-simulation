from __future__ import annotations

import json
from pathlib import Path

import pytest

from explanatory_analysis.query_engine import DataCatalog, NarratedAnswer, QueryExecutor, QueryPlan
from explanatory_analysis.rag import LocalRAG, Package, RAGConfig


def package(tmp_path: Path) -> Package:
    areas = [
        {
            "areaId": "flow-01",
            "kind": "flow_hotspot",
            "geometryM": {"type": "circle", "center": [2.0, 3.0], "radiusM": 0.5},
            "metrics": {"relativeIntensity": 1.0, "visitCount": 52, "uniqueVisitors": 18},
            "confidence": 0.9,
            "limitation": "di antara hotspot terdeteksi",
        },
        {
            "areaId": "flow-05",
            "kind": "flow_hotspot",
            "geometryM": {"type": "circle", "center": [8.0, 5.0], "radiusM": 0.4},
            "metrics": {"relativeIntensity": 0.1, "visitCount": 10, "uniqueVisitors": 6},
            "confidence": 0.8,
            "limitation": "di antara hotspot terdeteksi",
        },
    ]
    cards = [
        {"cardId": "card-01", "questionTypes": ["most_traversed_area"], "statement": "Arus tertinggi.", "areaId": "flow-01", "geometryM": areas[0]["geometryM"], "metrics": areas[0]["metrics"], "confidence": 0.9},
        {"cardId": "card-05", "questionTypes": ["least_traversed_area"], "statement": "Arus terendah di antara hotspot.", "areaId": "flow-05", "geometryM": areas[1]["geometryM"], "metrics": areas[1]["metrics"], "confidence": 0.8},
    ]
    manifest = {"schemaVersion": "2.0", "coordinateSystem": {"widthM": 10, "heightM": 7.5}, "floorplan": {}}
    return Package(tmp_path, "job", manifest, {"trackCount": 2}, areas, cards, {"capabilities": {}})


def service(tmp_path: Path) -> LocalRAG:
    return LocalRAG(RAGConfig(tmp_path, tmp_path / "out"), package(tmp_path))


def quiet_flow_plan() -> QueryPlan:
    return QueryPlan(
        mode="analytical",
        interpretation="Cari flow hotspot dengan intensitas relatif terendah.",
        assumption="Sepi ditafsirkan sebagai jarang dilewati.",
        alternativeInterpretations=["Kehadiran rendah"],
        dataset="spatial_areas",
        operation="rank",
        entityKinds=["flow_hotspot"],
        metrics=[{"field": "relativeIntensity", "aggregation": "value", "direction": "min", "weight": 1.0}],
        spatialAnswer=True,
        confidence=0.9,
    )


def test_query_plan_is_generic_and_rejects_extra_fields() -> None:
    plan = quiet_flow_plan()
    assert plan.metrics[0].direction == "min"
    with pytest.raises(Exception):
        QueryPlan.model_validate(plan.model_dump() | {"intent": "least_traversed"})
    with pytest.raises(Exception):
        QueryPlan(mode="general_knowledge", interpretation="x", assumption="x", dataset="spatial_areas", operation="lookup", entityKinds=[], spatialAnswer=True, confidence=0.5)


def test_complete_population_executor_selects_flow_05(tmp_path: Path) -> None:
    rag = service(tmp_path)
    result = rag.executor.execute(quiet_flow_plan())
    assert result["populationCount"] == 2
    assert result["selectedAreaId"] == "flow-05"
    assert result["rows"][0]["relativeIntensity"] == 0.1


def test_catalog_rejects_unknown_field_and_area(tmp_path: Path) -> None:
    rag = service(tmp_path)
    invalid_field_payload = quiet_flow_plan().model_dump()
    invalid_field_payload["metrics"] = [{"field": "invented", "aggregation": "value", "direction": "min", "weight": 1.0}]
    invalid_field = QueryPlan.model_validate(invalid_field_payload)
    with pytest.raises(ValueError):
        rag.catalog.validate_plan(invalid_field, rag.area_by_id)
    invalid_area = quiet_flow_plan().model_copy(update={"areaIds": ["hallucinated-area"]})
    with pytest.raises(ValueError):
        rag.catalog.validate_plan(invalid_area, rag.area_by_id)


def test_catalog_rejects_relative_intensity_across_area_kinds(tmp_path: Path) -> None:
    rag = service(tmp_path)
    mixed_plan = quiet_flow_plan().model_copy(
        update={"entityKinds": ["low_flow_area", "low_presence_area"]}
    )
    with pytest.raises(ValueError, match="tepat satu area kind"):
        rag.catalog.validate_plan(mixed_plan, rag.area_by_id)


def test_catalog_normalizes_explicit_kind_filter_without_language_router(tmp_path: Path) -> None:
    rag = service(tmp_path)
    payload = quiet_flow_plan().model_dump()
    payload["entityKinds"] = []
    payload["filters"] = [{"field": "kind", "operator": "eq", "value": "flow_hotspot"}]
    payload["metrics"].append(
        {"field": "flow_hotspot", "aggregation": "value", "direction": "min", "weight": 1.0}
    )
    normalized = rag.catalog.normalize_plan(QueryPlan.model_validate(payload))
    assert normalized.entityKinds == ["flow_hotspot"]
    assert [metric.field for metric in normalized.metrics] == ["relativeIntensity"]
    rag.catalog.validate_plan(normalized, rag.area_by_id)


def test_catalog_selects_first_structured_kind_and_records_other_as_alternative(tmp_path: Path) -> None:
    rag = service(tmp_path)
    mixed = quiet_flow_plan().model_copy(
        update={"entityKinds": ["flow_hotspot", "presence_hotspot"]}
    )
    normalized = rag.catalog.normalize_plan(mixed)
    assert normalized.entityKinds == ["flow_hotspot"]
    assert normalized.alternativeInterpretations == [
        "Kehadiran rendah",
        "Ranking alternatif untuk area kind presence_hotspot (tidak dieksekusi)",
    ]
    rag.catalog.validate_plan(normalized, rag.area_by_id)


def test_planner_payload_uses_thinking_and_structured_schema(tmp_path: Path) -> None:
    rag = service(tmp_path)
    payload = rag._planner_payload("Area mana yang jarang dilewati?", [], rag.config.thinking_num_predict)
    assert payload["think"] is False
    assert payload["options"]["num_predict"] == 512
    assert payload["options"]["num_ctx"] == 4096
    assert payload["format"]["title"] == "QueryPlan"


@pytest.mark.parametrize(
    ("question", "expected"),
    [
        ("Area mana yang paling ramai?", "max"),
        ("Area mana yang paling sepi atau jarang dilewati?", "min"),
    ],
)
def test_planner_repairs_only_missing_ranking_direction(question: str, expected: str) -> None:
    payload = quiet_flow_plan().model_dump()
    payload["metrics"][0]["direction"] = "none"
    parsed = LocalRAG._parse_query_plan(json.dumps(payload), question)
    assert parsed.metrics[0].direction == expected


def test_truncated_planner_is_retried_and_second_plan_is_used(tmp_path: Path) -> None:
    rag = service(tmp_path)
    rag.semantic_hints = lambda question: []
    thinking_modes = []
    responses = iter([
        {"message": {"thinking": "belum selesai", "content": ""}, "done_reason": "length", "eval_count": 1024},
        {"message": {"thinking": "selesai", "content": quiet_flow_plan().model_dump_json()}, "done_reason": "stop", "eval_count": 300},
    ])
    def chat(payload):
        thinking_modes.append(payload["think"])
        return next(responses)

    rag.client.chat = chat
    plan, thinking, audit, _ = rag.plan_question("Area mana yang jarang dilewati?")
    assert plan.metrics[0].direction == "min"
    assert audit["status"] == "retry_succeeded"
    assert audit["usedAttempt"] == 2
    assert "belum selesai" in thinking and "selesai" in thinking
    assert thinking_modes == [False, True]


def test_valid_compact_plan_has_no_fake_raw_thinking(tmp_path: Path) -> None:
    rag = service(tmp_path)
    rag.semantic_hints = lambda question: []
    rag.client.chat = lambda payload: {
        "message": {"content": quiet_flow_plan().model_dump_json()},
        "done_reason": "stop",
        "eval_count": 120,
    }
    _, thinking, audit, _ = rag.plan_question("Area mana yang jarang dilewati?")
    assert thinking == ""
    assert audit["thinkingMode"] == "adaptive"
    assert audit["attempts"][0]["thinkingEnabled"] is False


def test_executor_area_cannot_be_replaced_by_narrator(tmp_path: Path) -> None:
    rag = service(tmp_path)
    rag.plan_question = lambda question: (quiet_flow_plan(), "thinking", {"status": "complete", "attempts": [], "truncated": False}, [])
    rag.retrieve = lambda question, execution=None: [dict(rag.package.cards[1])]
    rag.narrate = lambda question, plan, execution, evidence: (NarratedAnswer(answer="Flow-01 menurut narasi yang salah.", limitations=[], requiredData=[]), {})
    result = rag.ask("Area mana yang jarang dilewati?", show=False)
    assert result["selectedAreaId"] == "flow-05"
    assert result["selectedArea"] == rag.area_by_id["flow-05"]
    assert result["provenance"]["areaSelectionAuthority"] == "query_executor"
    manifest_path = Path(result["artifacts"]["runDirectory"]) / "run_manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert manifest["models"]["planner"] == "qwen3:14b"
    assert manifest["configuration"]["maximumPlannerRetries"] == 1
    assert "usageAndLatency" in manifest


def test_narrator_retries_when_official_selected_area_is_missing(tmp_path: Path) -> None:
    rag = service(tmp_path)
    execution = rag.executor.execute(quiet_flow_plan())
    responses = iter([
        {"message": {"content": NarratedAnswer(answer="Flow-01 paling tinggi.", limitations=[], requiredData=[]).model_dump_json()}},
        {"message": {"content": NarratedAnswer(answer="Area terpilih adalah flow-05 dengan intensitas paling rendah.", limitations=[], requiredData=[]).model_dump_json()}},
    ])
    rag.client.chat = lambda payload: next(responses)
    narrated, usage = rag.narrate("Area mana yang jarang dilewati?", quiet_flow_plan(), execution, rag.package.cards)
    assert narrated.answer == "Area terpilih adalah flow-05 dengan intensitas paling rendah."
    assert usage["attempts"] == 2


def test_short_narration_uses_deterministic_executor_summary(tmp_path: Path) -> None:
    rag = service(tmp_path)
    execution = rag.executor.execute(quiet_flow_plan())
    rag.client.chat = lambda payload: {
        "message": {"content": NarratedAnswer(answer="flow-05", limitations=[], requiredData=[]).model_dump_json()},
        "total_duration": 1_000_000,
    }
    narrated, usage = rag.narrate("Area mana yang jarang dilewati?", quiet_flow_plan(), execution, rag.package.cards)
    assert "Area terpilih adalah flow-05" in narrated.answer
    assert "relativeIntensity 0.1" in narrated.answer
    assert "2 flow_hotspot" in narrated.answer
    assert usage["deterministicShortAnswerFallback"] is True


def test_general_knowledge_answer_has_no_area_or_overlay(tmp_path: Path) -> None:
    rag = service(tmp_path)
    plan = QueryPlan(mode="general_knowledge", interpretation="Pertanyaan pengetahuan umum.", assumption="Tidak memakai data job.", operation="describe", entityKinds=[], confidence=0.8)
    rag.plan_question = lambda question: (plan, "thinking", {"status": "complete", "attempts": [], "truncated": False}, [])
    rag.retrieve = lambda question, execution=None: []
    rag.narrate = lambda question, plan, execution, evidence: (NarratedAnswer(answer="Pengetahuan umum, bukan hasil trajectory.", limitations=[], requiredData=[]), {})
    result = rag.ask("Bagaimana meningkatkan kepuasan pengunjung?", show=False)
    assert result["dataGrounding"] == "general_knowledge"
    assert result["supportLevel"] == "unsupported"
    assert result["selectedArea"] is None
    assert result["artifacts"]["floorplanOverlay"] is None


def test_overlay_failure_keeps_completed_text_answer(tmp_path: Path) -> None:
    rag = service(tmp_path)
    rag.plan_question = lambda question: (quiet_flow_plan(), "thinking", {"status": "complete", "attempts": [], "truncated": False}, [])
    rag.retrieve = lambda question, execution=None: [dict(rag.package.cards[1])]
    rag.narrate = lambda question, plan, execution, evidence: (NarratedAnswer(answer="Area terpilih adalah flow-05.", limitations=[], requiredData=[]), {})
    rag._render_overlay = lambda run_dir, final: (_ for _ in ()).throw(RuntimeError("renderer unavailable"))

    result = rag.ask("Area mana yang jarang dilewati?", show=False)

    assert result["answer"] == "Area terpilih adalah flow-05."
    assert result["artifacts"]["floorplanOverlay"] is None
    assert "Overlay floorplan tidak dapat dibuat: renderer unavailable" in result["limitations"]
    saved = json.loads((Path(result["artifacts"]["runDirectory"]) / "response.json").read_text())
    assert saved["answer"] == result["answer"]


def test_session_context_is_limited_to_six_turns(tmp_path: Path) -> None:
    rag = service(tmp_path)
    rag.history = [{"question": f"q{i}", "answer": f"a{i}", "selectedAreaId": "flow-01", "queryPlan": {"interpretation": f"i{i}"}, "artifacts": {"runId": f"run-{i}"}} for i in range(8)]
    context = rag._session_context()
    assert len(context) == 6
    assert context[0]["question"] == "q2"
    assert "thinking" not in context[0]


def test_saved_new_and_legacy_runs_are_loadable(tmp_path: Path) -> None:
    rag = service(tmp_path)
    new_dir = tmp_path / "out" / "job" / "llm-rag-v2" / "runs" / "20260811T130000.000000Z-new"
    old_dir = tmp_path / "out" / "job" / "llm-rag-v1" / "runs" / "20260811T120000.000000Z-old"
    for run_dir in (new_dir, old_dir):
        run_dir.mkdir(parents=True)
        (run_dir / "response.json").write_text(json.dumps({"question": run_dir.name, "supportLevel": "supported", "answer": "x", "artifacts": {}}), encoding="utf-8")
        (run_dir / "retrieved_evidence.json").write_text(json.dumps({"cards": []}), encoding="utf-8")
        (run_dir / "thinking.txt").write_text("audit", encoding="utf-8")
    (new_dir / "query_plan.json").write_text(quiet_flow_plan().model_dump_json(), encoding="utf-8")
    (new_dir / "execution_result.json").write_text(json.dumps({"selectedAreaId": "flow-05"}), encoding="utf-8")
    entries = rag.saved_runs()
    assert {entry["legacy"] for entry in entries} == {False, True}
    bundle = rag.load_saved_bundle(new_dir)
    assert bundle["legacy"] is False
    assert bundle["execution"]["selectedAreaId"] == "flow-05"


def test_scaled_canvas_still_renders_floorplan_overlay(tmp_path: Path) -> None:
    rag = service(tmp_path)
    run_dir = tmp_path / "rendered-run"
    run_dir.mkdir()
    overlay = rag._render_overlay(run_dir, {
        "selectedArea": rag.area_by_id["flow-05"],
        "selectedAreaId": "flow-05",
        "dataGrounding": "grounded",
        "supportLevel": "supported",
    })
    assert overlay == run_dir / "floorplan_overlay.png"
    assert overlay.is_file()
