from __future__ import annotations

import json
from pathlib import Path

import pytest
from PIL import Image

from explanatory_analysis.local_model import LocalModelRuntime
from explanatory_analysis.rag import LocalRAG, Package, RAGConfig


class FakeGenerator:
    def __init__(self, text: str = "Ringkasan data tersedia. [[SUPPORT:supported]] [[AREA_ID:none]]") -> None:
        self.text = text
        self.calls: list[list[dict[str, str]]] = []

    def generate(self, messages: list[dict[str, str]], max_tokens: int = 256) -> dict:
        self.calls.append(messages)
        return {"text": self.text, "thinking": "Saya membandingkan kandidat yang relevan.", "promptTokens": 100, "completionTokens": 20}


def package(tmp_path: Path) -> Package:
    areas = [
        {
            "areaId": "flow-01", "label": "Area Arus Ramai", "kind": "flow_hotspot",
            "geometryM": {"type": "circle", "center": [2.0, 3.0], "radiusM": 0.5},
            "metrics": {"relativeIntensity": 1.0, "totalPathLengthM": 100.0, "uniqueVisitors": 18},
            "confidence": 0.9, "limitation": "Area arus bersifat observasional.",
        },
        {
            "areaId": "flow-05", "label": "Area Arus Sepi", "kind": "flow_hotspot",
            "geometryM": {"type": "circle", "center": [8.0, 5.0], "radiusM": 0.4},
            "metrics": {"relativeIntensity": 0.1, "totalPathLengthM": 10.0, "uniqueVisitors": 6},
            "confidence": 0.8, "limitation": "Area arus bersifat observasional.",
        },
        {
            "areaId": "table-01", "label": "Meja 1", "kind": "table",
            "geometryM": {"type": "polygon", "points": [[1, 1], [2, 1], [2, 2], [1, 2]]},
            "interactionGeometryM": {"type": "polygon", "points": [[0.5, 0.5], [2.5, 0.5], [2.5, 2.5], [0.5, 2.5]]},
            "metrics": {"tableAreaM2": 1.0, "interactionAreaM2": 3.0, "meanVisitDurationSec": 10.0, "uniqueVisitors": 12, "visitCount": 20},
            "confidence": 1.0,
        },
        {
            "areaId": "table-02", "label": "Meja 2", "kind": "table",
            "geometryM": {"type": "polygon", "points": [[4, 1], [6, 1], [6, 2], [4, 2]]},
            "interactionGeometryM": {"type": "polygon", "points": [[3.5, 0.5], [6.5, 0.5], [6.5, 2.5], [3.5, 2.5]]},
            "metrics": {"tableAreaM2": 2.0, "interactionAreaM2": 5.0, "meanVisitDurationSec": 45.0, "uniqueVisitors": 4, "visitCount": 8},
            "confidence": 1.0,
        },
    ]
    cards = [
        {"cardId": "flow-high", "questionTypes": ["most_traversed_area", "layout"], "statement": "Arus tertinggi berada di Area Arus Ramai.", "areaId": "flow-01", "metrics": areas[0]["metrics"], "limitation": areas[0]["limitation"]},
        {"cardId": "flow-low", "questionTypes": ["least_traversed_area", "layout"], "statement": "Arus terendah berada di Area Arus Sepi.", "areaId": "flow-05", "metrics": areas[1]["metrics"], "limitation": areas[1]["limitation"]},
        {"cardId": "table-01-card", "questionTypes": ["table_analysis", "table_usage"], "statement": "Meja 1 teranotasi.", "areaId": "table-01", "metrics": areas[2]["metrics"]},
        {"cardId": "table-02-card", "questionTypes": ["table_analysis", "table_usage"], "statement": "Meja 2 teranotasi.", "areaId": "table-02", "metrics": areas[3]["metrics"]},
    ]
    manifest = {
        "schemaVersion": "2.0", "jobId": "job", "coordinateSystem": {"widthM": 10, "heightM": 7.5}, "floorplan": {},
    }
    return Package(tmp_path, "job", manifest, {"trackCount": 18}, areas, cards, {"capabilities": {}})


def service(tmp_path: Path, generator: FakeGenerator | None = None) -> tuple[LocalRAG, FakeGenerator]:
    fake = generator or FakeGenerator()
    config = RAGConfig(tmp_path, tmp_path / "out")
    return LocalRAG(config, package(tmp_path), run_root=tmp_path / "runs", generator=fake), fake


@pytest.mark.parametrize(
    ("question", "model_text", "expected_area"),
    [
        ("area paling jarang dilewati", "Area Arus Sepi memiliki intensitas terendah. [[SUPPORT:supported]] [[AREA_ID:flow-05]]", "flow-05"),
        ("meja mana yang paling ramai", "Meja 1 paling ramai berdasarkan 20 kunjungan dan 12 track unik. [[SUPPORT:supported]] [[AREA_ID:table-01]]", "table-01"),
        ("meja mana yang cocok buat main catur", "Meja 2 memberi area dan dwell lebih besar, tetapi kenyamanan tidak diukur CCTV. [[SUPPORT:partially_supported]] [[AREA_ID:table-02]]", "table-02"),
    ],
)
def test_general_qwen_reasoning_owns_answer_and_area_selection(
    tmp_path: Path,
    question: str,
    model_text: str,
    expected_area: str,
) -> None:
    rag, generator = service(tmp_path, FakeGenerator(model_text))
    result = rag.ask(question, show=False)

    assert result["selectedAreaId"] == expected_area
    assert result["provenance"]["areaSelectionAuthority"] == "qwen_reasoning_validated"
    assert result["usage"]["generation"]["modelCallCount"] == 1
    assert len(generator.calls) == 1
    assert "[[AREA_ID:" not in result["answer"]
    assert generator.calls[0][0]["content"].startswith("/think")
    prompt_context = json.loads(generator.calls[0][1]["content"])
    catalog_ids = {line.split("|", 1)[0] for line in prompt_context["areaCatalog"].splitlines()}
    assert catalog_ids == {
        "flow-01", "flow-05", "table-01", "table-02",
    }
    run_dir = Path(result["artifacts"]["runDirectory"])
    assert (run_dir / "grounding.json").is_file()
    assert (run_dir / "reasoning.txt").is_file()
    assert not (run_dir / "query_plan.json").exists()
    assert not (run_dir / "thinking.txt").exists()
    manifest = json.loads((run_dir / "run_manifest.json").read_text(encoding="utf-8"))
    assert manifest["configuration"]["maximumModelCalls"] == 1
    assert manifest["configuration"]["thinking"] is True


def test_layout_question_is_answered_without_structured_output(tmp_path: Path) -> None:
    rag, generator = service(tmp_path)
    result = rag.ask("analisis layoutnya", show=False)

    assert result["grounding"]["mode"] == "qwen_general_reasoning"
    assert result["answer"]
    assert len(generator.calls) == 1
    assert result["selectedAreaId"] is None


def test_model_failure_is_reported_instead_of_inventing_a_backend_answer(tmp_path: Path) -> None:
    class FailingGenerator(FakeGenerator):
        def generate(self, messages: list[dict[str, str]], max_tokens: int = 256) -> dict:
            self.calls.append(messages)
            raise RuntimeError("runtime unavailable")

    generator = FailingGenerator()
    rag, _ = service(tmp_path, generator)
    with pytest.raises(RuntimeError, match="runtime unavailable"):
        rag.ask("area paling jarang dilewati", show=False)
    assert len(generator.calls) == 1


def test_invalid_area_marker_keeps_model_answer_but_does_not_create_overlay(tmp_path: Path) -> None:
    rag, _ = service(tmp_path, FakeGenerator("Data belum cukup untuk memilih satu area. [[SUPPORT:unsupported]] [[AREA_ID:made-up]]"))
    result = rag.ask("bagaimana kondisi pencahayaannya?", show=False)
    assert result["answer"] == "Data belum cukup untuk memilih satu area."
    assert result["selectedAreaId"] is None
    assert result["supportLevel"] == "unsupported"
    assert result["usage"]["generation"]["areaMarkerValid"] is False
    assert result["artifacts"]["floorplanOverlay"] is None


def test_incomplete_control_marker_is_never_shown_to_user(tmp_path: Path) -> None:
    rag, _ = service(
        tmp_path,
        FakeGenerator("Meja 1 paling ramai. [[SUPPORT:supported]] [[AREA_ID:table-01"),
    )
    result = rag.ask("meja paling ramai", show=False)
    assert result["answer"] == "Meja 1 paling ramai."
    assert "[[" not in result["answer"]


def test_length_limited_completion_is_not_saved_as_a_partial_answer(tmp_path: Path) -> None:
    class TruncatedGenerator(FakeGenerator):
        def generate(self, messages: list[dict[str, str]], max_tokens: int = 256) -> dict:
            self.calls.append(messages)
            return {
                "text": "Jawaban ini masih terpotong karena",
                "finishReason": "length",
                "completionTokens": max_tokens,
            }

    rag, _ = service(tmp_path, TruncatedGenerator())
    with pytest.raises(RuntimeError, match="mencapai batas generasi"):
        rag.ask("jelaskan semua meja", show=False)
    assert not (tmp_path / "runs").exists()


def test_internal_area_ids_are_replaced_with_user_facing_labels(tmp_path: Path) -> None:
    rag, _ = service(
        tmp_path,
        FakeGenerator("table-01 lebih ramai daripada table-02. [[SUPPORT:supported]] [[AREA_ID:table-01]]"),
    )
    result = rag.ask("bandingkan meja", show=False)
    assert result["answer"] == "Meja 1 lebih ramai daripada Meja 2."


def test_unclosed_thinking_block_is_not_treated_as_visible_answer() -> None:
    answer, thinking = LocalModelRuntime._split_thinking("<think>analisis yang belum selesai")
    assert answer == ""
    assert thinking == "analisis yang belum selesai"


def test_overlay_contains_only_floorplan_canvas_without_side_metadata(tmp_path: Path) -> None:
    rag, _ = service(tmp_path, FakeGenerator("Area Arus Sepi memiliki arus terendah. [[SUPPORT:supported]] [[AREA_ID:flow-05]]"))
    result = rag.ask("area paling jarang dilewati", show=False)
    overlay = Path(result["artifacts"]["floorplanOverlay"])
    with Image.open(overlay) as image:
        ratio = image.width / image.height
    assert ratio == pytest.approx(10 / 7.5, rel=0.03)


def test_existing_model_is_not_downloaded_again(tmp_path: Path) -> None:
    target = tmp_path / "Qwen3-8B-Q4_K_M.gguf"
    target.write_bytes(b"valid-model")
    calls = 0

    def download(_: str, __: str, ___: Path) -> Path:
        nonlocal calls
        calls += 1
        return target

    runtime = LocalModelRuntime(target, download=download, minimum_model_bytes=4)
    assert runtime.ensure_model() == target
    assert calls == 0


def test_failed_download_leaves_no_valid_or_partial_model(tmp_path: Path) -> None:
    target = tmp_path / "Qwen3-8B-Q4_K_M.gguf"

    def download(_: str, __: str, cache: Path) -> Path:
        cache.mkdir(parents=True, exist_ok=True)
        broken = cache / "broken.gguf"
        broken.write_bytes(b"x")
        return broken

    runtime = LocalModelRuntime(target, download=download, minimum_model_bytes=4)
    with pytest.raises(RuntimeError, match="tidak lengkap"):
        runtime.ensure_model()
    assert not target.exists()
    assert list(tmp_path.glob("*.partial")) == []


def test_saved_legacy_session_run_remains_loadable(tmp_path: Path) -> None:
    rag, _ = service(tmp_path)
    old_dir = tmp_path / "runs" / "20260811T120000.000000Z-old"
    old_dir.mkdir(parents=True)
    (old_dir / "response.json").write_text(json.dumps({"question": "lama", "supportLevel": "supported", "answer": "x", "artifacts": {}}), encoding="utf-8")
    (old_dir / "retrieved_evidence.json").write_text(json.dumps({"cards": []}), encoding="utf-8")
    (old_dir / "thinking.txt").write_text("audit lama", encoding="utf-8")
    bundle = rag.load_saved_bundle(old_dir)
    assert bundle["legacy"] is True
    assert bundle["response"]["answer"] == "x"
