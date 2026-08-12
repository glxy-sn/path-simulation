from __future__ import annotations

import json
from pathlib import Path

import pytest

from explanatory_service import (
    AnalysisContextUpdate,
    ChatSessionCreate,
    ChatSessionManager,
    ChatSessionPatch,
    CustomZoneContext,
    ExplanatoryManager,
    RectContext,
)


def write_job(root: Path, job_id: str, tables: list[dict] | None = None) -> Path:
    directory = root / job_id
    directory.mkdir(parents=True)
    (directory / "job.json").write_text(json.dumps({
        "venue": {
            "widthM": 10,
            "heightM": 7.5,
            "name": "Test",
            "type": "foodcourt",
            "floorPlanPath": None,
            "tables": tables or [],
        },
        "cameras": [],
    }), encoding="utf-8")
    return directory


def test_context_converts_drag_rectangle_to_four_point_table(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("explanatory_service.Config.WORKDIR", tmp_path)
    directory = write_job(tmp_path, "job-a", [{
        "id": "table-01",
        "label": "Meja Utama",
        "verified": True,
        "rectNormalized": {"x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4},
    }])
    manager = ExplanatoryManager()
    context = manager._ensure_context(directory)
    for actual, expected in zip(
        context["tables"][0]["geometryNormalized"]["points"],
        [[0.1, 0.2], [0.4, 0.2], [0.4, 0.6], [0.1, 0.6]],
    ):
        assert actual == pytest.approx(expected)
    assert context["tables"][0]["geometryM"]["points"][2] == pytest.approx([4.0, 4.5])


def test_each_job_has_independent_multiple_chat_sessions(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("explanatory_service.Config.WORKDIR", tmp_path)
    write_job(tmp_path, "job-a")
    write_job(tmp_path, "job-b")
    explanatory = ExplanatoryManager()
    chats = ChatSessionManager(explanatory)

    first = chats.create("job-a", ChatSessionCreate(title="Area ramai"))
    second = chats.create("job-a", ChatSessionCreate(title="Evaluasi meja"))
    foreign = chats.create("job-b", ChatSessionCreate(title="Peak hour"))

    assert {item["sessionId"] for item in chats.list("job-a")} == {first["sessionId"], second["sessionId"]}
    assert {item["sessionId"] for item in chats.list("job-b")} == {foreign["sessionId"]}
    with pytest.raises(FileNotFoundError):
        chats.get("job-a", foreign["sessionId"])


def test_chat_session_rename_and_delete_persist(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("explanatory_service.Config.WORKDIR", tmp_path)
    write_job(tmp_path, "job-a")
    chats = ChatSessionManager(ExplanatoryManager())
    session = chats.create("job-a", ChatSessionCreate())
    renamed = chats.rename("job-a", session["sessionId"], ChatSessionPatch(title="Jalur pengunjung"))
    assert renamed["title"] == "Jalur pengunjung"

    reloaded = ChatSessionManager(ExplanatoryManager())
    assert reloaded.get("job-a", session["sessionId"])["title"] == "Jalur pengunjung"
    reloaded.delete("job-a", session["sessionId"])
    assert reloaded.list("job-a") == []


def test_custom_zone_update_increments_revision_and_forces_rebuild(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("explanatory_service.Config.WORKDIR", tmp_path)
    directory = write_job(tmp_path, "job-a")
    manager = ExplanatoryManager()
    manager._ensure_context(directory)
    build_calls: list[tuple[str, bool]] = []
    monkeypatch.setattr(manager, "build", lambda job_id, force=False: build_calls.append((job_id, force)) or {"state": "building"})

    response = manager.update_context("job-a", AnalysisContextUpdate(customZones=[
        CustomZoneContext(
            id="zone-fixed",
            label="Zona Uji",
            rectNormalized=RectContext(x=0.1, y=0.2, width=0.3, height=0.2),
        )
    ]))

    persisted = json.loads((directory / "analysis-context.json").read_text(encoding="utf-8"))
    assert response["state"] == "building"
    assert persisted["contextRevision"] == 2
    assert persisted["customZones"][0]["id"] == "zone-fixed"
    assert build_calls == [("job-a", True)]
