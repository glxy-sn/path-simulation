from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd
from PIL import Image, ImageDraw

from explanatory_analysis.pipeline import (
    AnalysisConfig,
    build_crowd_bottleneck,
    build_group_episodes,
    build_spatial_density_table,
    density_surface,
    extract_low_activity_areas,
    prepare_trajectory,
    validate_table_context,
    venue_fingerprint,
)


def config(tmp_path: Path) -> AnalysisConfig:
    return AnalysisConfig(tmp_path, tmp_path / "work", tmp_path / "output")


def raw_track() -> pd.DataFrame:
    return pd.DataFrame({
        "t": [0.0, 0.2, 0.4, 2.0, 2.2, 0.0],
        "id": [1, 1, 1, 1, 1, 2],
        "x": [1.0, 1.1, 1.2, 8.0, 8.1, 11.0],
        "y": [1.0, 1.0, 1.0, 6.0, 6.0, 2.0],
        "identityScore": [0.9] * 6,
        "identityLevel": ["multiCamera"] * 6,
    })


def test_gap_and_out_of_venue_are_not_bridged(tmp_path: Path) -> None:
    frame, _ = prepare_trajectory(raw_track(), 10.0, 7.5, 0.0, config(tmp_path))
    track = frame.loc[frame["id"] == 1]
    assert track["segmentId"].nunique() == 2
    assert float(track["pathStepM"].sum()) < 1.0
    invalid = frame.loc[frame["id"] == 2].iloc[0]
    assert not bool(invalid["inVenue"])
    assert pd.isna(invalid["xSmoothM"])


def test_density_integral_uses_observed_time_and_is_smooth(tmp_path: Path) -> None:
    rows = []
    for index in range(30):
        rows.append({"t": index * 0.2, "id": 1, "x": 5 + index * 0.01, "y": 3.5, "identityScore": 1.0, "identityLevel": "singleCamera"})
    frame, _ = prepare_trajectory(pd.DataFrame(rows), 10.0, 7.5, 0.0, config(tmp_path))
    density = density_surface(frame, 10.0, 7.5, config(tmp_path), "presence")
    integral = float(density["surface"].sum() * density["cellAreaM2"])
    assert np.isclose(integral, frame["observedIntervalSec"].sum(), rtol=1e-6)
    assert np.count_nonzero(density["surface"] > density["surface"].max() * 0.1) > 20


def test_low_activity_area_stays_inside_observed_support(tmp_path: Path) -> None:
    rows = []
    for track_id, offset in ((1, 0.0), (2, 0.15)):
        for index in range(80):
            rows.append({"t": index * 0.2, "id": track_id, "x": 1 + 8 * index / 79, "y": 3 + offset, "identityScore": 1.0, "identityLevel": "singleCamera"})
    frame, _ = prepare_trajectory(pd.DataFrame(rows), 10.0, 7.5, 0.0, config(tmp_path))
    presence = density_surface(frame, 10.0, 7.5, config(tmp_path), "presence")
    flow = density_surface(frame, 10.0, 7.5, config(tmp_path), "flow")
    areas = extract_low_activity_areas(flow, presence, 10.0, 7.5, config(tmp_path), 1.0)
    assert areas
    assert areas[0]["kind"] == "low_flow_area"
    assert "observed-support envelope" in areas[0]["limitation"]
    surface = build_spatial_density_table(presence, flow, config(tmp_path))
    assert {"presenceSecPerM2", "flowMPerM2", "insideObservedSupport"}.issubset(surface.columns)
    assert surface["insideObservedSupport"].any()


def test_stable_comoving_pair_and_solo_ratio(tmp_path: Path) -> None:
    rows = []
    for second in range(8):
        rows.extend([
            {"timeSec": second, "trackId": "a", "segmentId": "a:1", "xM": second * 0.2, "yM": 1.0, "speedMps": 0.2, "headingDeg": 0.0},
            {"timeSec": second, "trackId": "b", "segmentId": "b:1", "xM": second * 0.2, "yM": 1.8, "speedMps": 0.2, "headingDeg": 0.0},
        ])
    episodes, summary = build_group_episodes(pd.DataFrame(rows), config(tmp_path))
    assert len(episodes) == 1
    assert int(episodes.iloc[0]["groupSize"]) == 2
    assert summary["soloObservationRatio"] == 0.0


def test_perceptual_venue_fingerprint_survives_image_format(tmp_path: Path) -> None:
    image = Image.new("RGB", (300, 200), "white")
    draw = ImageDraw.Draw(image)
    draw.rectangle((40, 30, 250, 160), fill="#999999")
    png, jpeg = tmp_path / "floor.png", tmp_path / "floor.jpg"
    image.save(png)
    image.save(jpeg, quality=95)
    assert venue_fingerprint(png, 10.0, 7.5) == venue_fingerprint(jpeg, 10.0, 7.5)


def test_table_polygon_must_be_valid_and_inside_venue() -> None:
    valid = {"tables": [{"featureId": "table-01", "geometryM": {"points": [[1, 1], [2, 1], [2, 2], [1, 2]]}}]}
    validate_table_context(valid, 10.0, 7.5)
    invalid = {"tables": [{"featureId": "table-01", "geometryM": {"points": [[1, 1], [11, 1], [2, 2]]}}]}
    try:
        validate_table_context(invalid, 10.0, 7.5)
    except ValueError:
        pass
    else:
        raise AssertionError("Out-of-bounds polygon should fail")


def test_table_polygons_must_not_overlap() -> None:
    context = {"tables": [
        {"featureId": "table-01", "geometryM": {"points": [[1, 1], [3, 1], [3, 3], [1, 3]]}},
        {"featureId": "table-02", "geometryM": {"points": [[2, 2], [4, 2], [4, 4], [2, 4]]}},
    ]}
    try:
        validate_table_context(context, 10.0, 7.5)
    except ValueError:
        pass
    else:
        raise AssertionError("Overlapping table polygons should fail")


def test_no_group_for_short_pair(tmp_path: Path) -> None:
    rows = []
    for second in range(4):
        rows.extend([
            {"timeSec": second, "trackId": "a", "segmentId": "a:1", "xM": 1.0, "yM": 1.0, "speedMps": 0.2, "headingDeg": 0.0},
            {"timeSec": second, "trackId": "b", "segmentId": "b:1", "xM": 1.4, "yM": 1.0, "speedMps": 0.2, "headingDeg": 0.0},
        ])
    episodes, summary = build_group_episodes(pd.DataFrame(rows), config(tmp_path))
    assert episodes.empty
    assert summary["maxObservedGroupSize"] == 1


def test_persistent_density_and_speed_drop_forms_bottleneck() -> None:
    samples = []
    for second in range(5):
        for track in ("a", "b", "c"):
            samples.append({"timeSec": second, "trackId": track, "segmentId": f"{track}:1", "xM": 2.1, "yM": 2.1, "speedMps": 0.1, "headingDeg": 0.0})
    baseline = pd.DataFrame({"id": ["a", "b", "c"], "speedMps": [1.0, 1.0, 1.0], "usableForMovement": [True, True, True]})
    _, _, areas = build_crowd_bottleneck(pd.DataFrame(samples), baseline, 10.0, 7.5, 1.0)
    assert len(areas) == 1
    assert areas[0]["metrics"]["congestedSeconds"] == 5
