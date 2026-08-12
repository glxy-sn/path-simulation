"""Appearance-led local stitching and constrained multi-camera association."""
from __future__ import annotations

from dataclasses import dataclass
from itertools import combinations

import numpy as np
from scipy.optimize import linear_sum_assignment

from .tracklet import Tracklet, appearance_similarity


@dataclass
class FusionResult:
    global_tracks: dict[int, list[tuple[float, float, float]]]
    cam_to_global: dict[tuple[int, int], int]
    identity_confidence: dict[int, dict]
    diagnostics: list[dict]
    local_stitches: int
    overlap_merges: int
    handover_merges: int
    unmatched_tracklets: int
    filtered_tracklets: int


class _UnionFind:
    def __init__(self, size: int):
        self.parents = list(range(size))

    def find(self, value: int) -> int:
        while self.parents[value] != value:
            self.parents[value] = self.parents[self.parents[value]]
            value = self.parents[value]
        return value

    def union(self, left: int, right: int) -> int:
        left_root, right_root = self.find(left), self.find(right)
        if left_root != right_root:
            self.parents[right_root] = left_root
        return left_root


def _candidate_record(a: Tracklet, b: Tracklet, mode: str, **values) -> dict:
    record = {
        "cameraA": a.camera_idx,
        "localIdsA": sorted(a.source_local_ids),
        "cameraB": b.camera_idx,
        "localIdsB": sorted(b.source_local_ids),
        "mode": mode,
        "similarity": None,
        "medianDistanceM": None,
        "p95DistanceM": None,
        "gapSeconds": None,
        "speedMps": None,
        "score": None,
        "decision": "rejected",
        "reason": "notEvaluated",
    }
    record.update(values)
    return record


def _hungarian(records: list[dict], left_count: int, right_count: int) -> set[int]:
    if not records or left_count == 0 or right_count == 0:
        return set()
    matrix = np.full((left_count, right_count), 1e6, dtype=np.float64)
    lookup = {}
    for index, record in enumerate(records):
        if record["reason"] == "eligible":
            row, column = record["_row"], record["_column"]
            cost = 1.0 - float(record["score"])
            if cost < matrix[row, column]:
                matrix[row, column] = cost
                lookup[(row, column)] = index
    rows, columns = linear_sum_assignment(matrix)
    selected = set()
    for row, column in zip(rows, columns):
        index = lookup.get((int(row), int(column)))
        if index is not None and matrix[row, column] < 1e5:
            selected.add(index)
    return selected


def _local_candidates(tracklets: list[Tracklet], cfg) -> list[dict]:
    records = []
    interval = 1.0 / max(float(cfg.PROC_FPS), 1e-6)
    for row, first in enumerate(tracklets):
        for column, second in enumerate(tracklets):
            if first is second:
                continue
            gap = second.start_time - first.end_time
            if gap < 0:
                continue
            distance = float(np.linalg.norm(np.subtract(first.end_position, second.start_position)))
            speed = distance / max(gap, interval)
            similarity = appearance_similarity(first, second, cfg.REID_MIN_SAMPLES)
            reason = "eligible"
            if gap > cfg.LOCAL_STITCH_MAX_GAP_SEC:
                reason = "gapTooLong"
            elif similarity is None:
                reason = "insufficientEmbeddingSamples"
            elif similarity < cfg.LOCAL_STITCH_MIN_SIM:
                reason = "appearanceBelowThreshold"
            elif distance > cfg.LOCAL_STITCH_MAX_DIST_M:
                reason = "endpointDistanceTooLarge"
            elif speed > cfg.LOCAL_STITCH_MAX_SPEED_MPS:
                reason = "impossibleSpeed"
            continuity = max(0.0, 1.0 - speed / max(cfg.LOCAL_STITCH_MAX_SPEED_MPS, 1e-6))
            score = None if similarity is None else 0.7 * similarity + 0.3 * continuity
            records.append(
                _candidate_record(
                    first,
                    second,
                    "local",
                    similarity=similarity,
                    medianDistanceM=distance,
                    p95DistanceM=distance,
                    gapSeconds=gap,
                    speedMps=speed,
                    score=score,
                    reason=reason,
                    _row=row,
                    _column=column,
                )
            )
    return records


def stitch_local_tracklets(tracklets: list[Tracklet], cfg):
    """Repeated Hungarian matching within each camera, before global filtering."""
    by_camera: dict[int, list[Tracklet]] = {}
    for tracklet in tracklets:
        by_camera.setdefault(tracklet.camera_idx, []).append(tracklet)

    diagnostics, stitch_count = [], 0
    for camera_idx, current in by_camera.items():
        current = sorted(current, key=lambda item: (item.start_time, item.local_track_id))
        while True:
            records = _local_candidates(current, cfg)
            selected = _hungarian(records, len(current), len(current))
            accepted_pairs = []
            occupied = set()
            for index in sorted(selected, key=lambda value: records[value]["score"], reverse=True):
                record = records[index]
                row, column = record["_row"], record["_column"]
                if row in occupied or column in occupied or row == column:
                    continue
                occupied.update((row, column))
                record["decision"] = "accepted"
                record["reason"] = "hungarianMatch"
                accepted_pairs.append((row, column))
            for record in records:
                if record["reason"] == "eligible":
                    record["reason"] = "notSelectedByHungarian"
                record.pop("_row", None)
                record.pop("_column", None)
            diagnostics.extend(records)
            if not accepted_pairs:
                break

            replacements, consumed = [], set()
            for row, column in accepted_pairs:
                if row in consumed or column in consumed:
                    continue
                replacements.append(current[row].merged_with(current[column]))
                consumed.update((row, column))
                stitch_count += 1
            replacements.extend(item for index, item in enumerate(current) if index not in consumed)
            current = sorted(replacements, key=lambda item: (item.start_time, item.local_track_id))
        by_camera[camera_idx] = current
    stitched = [item for camera in sorted(by_camera) for item in by_camera[camera]]
    return stitched, diagnostics, stitch_count


def _overlap_distances(a: Tracklet, b: Tracklet) -> tuple[float, float] | None:
    start, end = max(a.start_time, b.start_time), min(a.end_time, b.end_time)
    if end <= start:
        return None
    left = np.asarray([obs[:3] for obs in a.floor_observations if start <= obs[0] <= end])
    right = np.asarray([obs[:3] for obs in b.floor_observations if start <= obs[0] <= end])
    if len(left) == 0 or len(right) == 0:
        return None
    sample = left if len(left) <= len(right) else right
    reference = right if sample is left else left
    x = np.interp(sample[:, 0], reference[:, 0], reference[:, 1])
    y = np.interp(sample[:, 0], reference[:, 0], reference[:, 2])
    distances = np.hypot(sample[:, 1] - x, sample[:, 2] - y)
    return float(np.median(distances)), float(np.percentile(distances, 95))


def _overlap_records(left: list[Tracklet], right: list[Tracklet], cfg) -> list[dict]:
    records = []
    for row, a in enumerate(left):
        for column, b in enumerate(right):
            overlap = min(a.end_time, b.end_time) - max(a.start_time, b.start_time)
            similarity = appearance_similarity(a, b, cfg.REID_MIN_SAMPLES)
            geometry = _overlap_distances(a, b)
            median, p95 = geometry if geometry is not None else (None, None)
            strict_gate = max(
                cfg.OVERLAP_BASE_RADIUS_M,
                float(np.hypot(a.calibration_uncertainty_m, b.calibration_uncertainty_m)) + 0.25,
            )
            appearance_match = (
                bool(getattr(cfg, "WITH_APP_FUSION", True))
                and similarity is not None
                and similarity >= cfg.OVERLAP_MIN_SIM
            )
            gate = max(
                strict_gate,
                getattr(cfg, "OVERLAP_APPEARANCE_RADIUS_M", strict_gate)
                if appearance_match
                else strict_gate,
            )
            reason = "eligible"
            if overlap < cfg.OVERLAP_MIN_SEC:
                reason = "overlapTooShort"
            elif similarity is None:
                reason = "insufficientEmbeddingSamples"
            elif not appearance_match:
                reason = "appearanceBelowThreshold"
            elif median is None:
                reason = "missingOverlapGeometry"
            elif median > gate:
                reason = "medianDistanceOutsideUncertaintyGate"
            elif p95 > 2.0 * gate:
                reason = "p95DistanceOutsideUncertaintyGate"
            spatial = 0.0 if median is None else max(0.0, 1.0 - median / max(gate, 1e-6))
            if appearance_match:
                score = 0.65 * similarity + 0.35 * spatial
                basis = "appearanceAndGeometry"
            else:
                score = None
                basis = None
            records.append(
                _candidate_record(
                    a,
                    b,
                    "overlap",
                    similarity=similarity,
                    medianDistanceM=median,
                    p95DistanceM=p95,
                    gapSeconds=-max(0.0, overlap),
                    score=score,
                    reason=reason,
                    uncertaintyGateM=gate,
                    associationBasis=basis,
                    _row=row,
                    _column=column,
                )
            )
    return records


def _handover_record(a: Tracklet, b: Tracklet, cfg) -> dict:
    first, second = (a, b) if a.end_time <= b.start_time else (b, a)
    gap = second.start_time - first.end_time
    distance = float(np.linalg.norm(np.subtract(first.end_position, second.start_position)))
    speed = distance / max(gap, 1.0 / max(float(cfg.PROC_FPS), 1e-6))
    similarity = appearance_similarity(first, second, cfg.REID_MIN_SAMPLES)
    reason = "eligible"
    if gap < 0:
        reason = "tracksOverlap"
    elif gap > cfg.HANDOVER_MAX_GAP_SEC:
        reason = "gapTooLong"
    elif similarity is None:
        reason = "insufficientEmbeddingSamples"
    elif similarity < cfg.HANDOVER_MIN_SIM:
        reason = "appearanceBelowThreshold"
    elif speed > cfg.HANDOVER_MAX_SPEED_MPS:
        reason = "impossibleSpeed"
    continuity = max(0.0, 1.0 - speed / max(cfg.HANDOVER_MAX_SPEED_MPS, 1e-6))
    score = None if similarity is None else 0.8 * similarity + 0.2 * continuity
    return _candidate_record(
        first,
        second,
        "handover",
        similarity=similarity,
        medianDistanceM=distance,
        p95DistanceM=distance,
        gapSeconds=gap,
        speedMps=speed,
        score=score,
        reason=reason,
        _from=first,
        _to=second,
    )


def _same_camera_overlap(members_a: set[int], members_b: set[int], tracklets: list[Tracklet]) -> bool:
    for left in members_a:
        for right in members_b:
            a, b = tracklets[left], tracklets[right]
            if a.camera_idx == b.camera_idx and min(a.end_time, b.end_time) > max(a.start_time, b.start_time):
                return True
    return False


def _overlap_cluster_conflict(members_a: set[int], members_b: set[int], tracklets, cfg) -> str | None:
    """Reject a transitive bridge when other simultaneous members disagree."""
    if _same_camera_overlap(members_a, members_b, tracklets):
        return "sameCameraTemporalConflict"
    for left in members_a:
        for right in members_b:
            a, b = tracklets[left], tracklets[right]
            overlap = min(a.end_time, b.end_time) - max(a.start_time, b.start_time)
            if a.camera_idx == b.camera_idx or overlap < cfg.OVERLAP_MIN_SEC:
                continue
            similarity = appearance_similarity(a, b, cfg.REID_MIN_SAMPLES)
            if similarity is None or similarity < cfg.OVERLAP_MIN_SIM:
                return "transitiveAppearanceConflict"
            geometry = _overlap_distances(a, b)
            if geometry is None:
                return "transitiveGeometryMissing"
            median, p95 = geometry
            gate = max(
                cfg.OVERLAP_BASE_RADIUS_M,
                float(np.hypot(a.calibration_uncertainty_m, b.calibration_uncertainty_m)) + 0.25,
            )
            if (
                bool(getattr(cfg, "WITH_APP_FUSION", True))
                and similarity >= cfg.OVERLAP_MIN_SIM
            ):
                gate = max(
                    gate,
                    getattr(cfg, "OVERLAP_APPEARANCE_RADIUS_M", gate),
                )
            if median > gate or p95 > 2 * gate:
                return "transitiveGeometryConflict"
    return None


def _weighted_global_track(members: list[Tracklet], fps: float):
    bins: dict[int, list[tuple[float, float, float, float]]] = {}
    for tracklet in members:
        sigma2 = max(tracklet.calibration_uncertainty_m ** 2, 0.01)
        for time, x, y, confidence in tracklet.floor_observations:
            weight = max(confidence, 0.05) / sigma2
            bins.setdefault(round(time * fps), []).append((x, y, weight, time))
    output = []
    for key in sorted(bins):
        values = bins[key]
        weights = np.asarray([value[2] for value in values])
        output.append(
            (
                float(np.average([value[3] for value in values], weights=weights)),
                float(np.average([value[0] for value in values], weights=weights)),
                float(np.average([value[1] for value in values], weights=weights)),
            )
        )
    return output


def fuse_tracklets(tracklets: list[Tracklet], cfg) -> FusionResult:
    stitched, diagnostics, local_stitches = stitch_local_tracklets(tracklets, cfg)
    kept, filtered = [], []
    for tracklet in stitched:
        if len(tracklet.floor_observations) >= cfg.MIN_TRACK_POINTS and tracklet.duration >= cfg.MIN_TRACK_SEC:
            kept.append(tracklet)
        else:
            filtered.append(tracklet)

    index_by_identity = {id(tracklet): index for index, tracklet in enumerate(kept)}
    overlap_selected = []
    cameras = sorted({tracklet.camera_idx for tracklet in kept})
    for first_camera, second_camera in combinations(cameras, 2):
        left = [item for item in kept if item.camera_idx == first_camera]
        right = [item for item in kept if item.camera_idx == second_camera]
        records = _overlap_records(left, right, cfg)
        selected = _hungarian(records, len(left), len(right))
        for index, record in enumerate(records):
            if index in selected:
                record["decision"] = "provisional"
                record["reason"] = "hungarianMatch"
                overlap_selected.append((record, left[record["_row"]], right[record["_column"]]))
            elif record["reason"] == "eligible":
                record["reason"] = "notSelectedByHungarian"
            record.pop("_row", None)
            record.pop("_column", None)
        diagnostics.extend(records)

    uf = _UnionFind(len(kept))
    members = {index: {index} for index in range(len(kept))}
    cluster_scores: dict[int, list[float]] = {index: [] for index in range(len(kept))}
    overlap_merges = 0
    for record, a, b in sorted(overlap_selected, key=lambda value: value[0]["score"], reverse=True):
        left, right = index_by_identity[id(a)], index_by_identity[id(b)]
        left_root, right_root = uf.find(left), uf.find(right)
        if left_root == right_root:
            record["decision"], record["reason"] = "rejected", "redundantTransitiveEdge"
            continue
        conflict = _overlap_cluster_conflict(
            members[left_root], members[right_root], kept, cfg
        )
        if conflict is not None:
            record["decision"], record["reason"] = "rejected", conflict
            continue
        root = uf.union(left_root, right_root)
        other = right_root if root == left_root else left_root
        members[root] = members.pop(left_root, set()) | members.pop(right_root, set())
        members.pop(other, None)
        cluster_scores[root] = cluster_scores.pop(left_root, []) + cluster_scores.pop(right_root, []) + [record["score"]]
        cluster_scores.pop(other, None)
        record["decision"], record["reason"] = "accepted", "clusterConstraintsPassed"
        overlap_merges += 1

    handover_records = []
    for a, b in combinations(kept, 2):
        if a.camera_idx != b.camera_idx and min(a.end_time, b.end_time) <= max(a.start_time, b.start_time):
            handover_records.append(_handover_record(a, b, cfg))

    # Freeze overlap components while selecting directed handovers. This permits a
    # linear A->B->C chain, while one component can never fan out to two successors.
    overlap_component = {index: uf.find(index) for index in range(len(kept))}
    successor, predecessor = {}, {}
    accepted_handovers = []
    for record in sorted(
        handover_records,
        key=lambda value: value["score"] if value["score"] is not None else -1.0,
        reverse=True,
    ):
        first, second = record.pop("_from"), record.pop("_to")
        if record["reason"] != "eligible":
            continue
        left, right = index_by_identity[id(first)], index_by_identity[id(second)]
        left_root, right_root = overlap_component[left], overlap_component[right]
        if left_root == right_root:
            record["reason"] = "redundantTransitiveEdge"
            continue
        if successor.get(left_root) is not None or predecessor.get(right_root) is not None:
            record["reason"] = "oneToManyConflict"
            continue
        if _same_camera_overlap(members[left_root], members[right_root], kept):
            record["reason"] = "sameCameraTemporalConflict"
            continue
        successor[left_root] = right_root
        predecessor[right_root] = left_root
        accepted_handovers.append((left_root, right_root, float(record["score"])))
        record["decision"], record["reason"] = "accepted", "clusterConstraintsPassed"
    handover_merges = len(accepted_handovers)

    for left_root, right_root, score in accepted_handovers:
        current_left, current_right = uf.find(left_root), uf.find(right_root)
        if current_left == current_right:
            continue
        left_scores = cluster_scores.pop(current_left, [])
        right_scores = cluster_scores.pop(current_right, [])
        left_members = members.pop(current_left, set())
        right_members = members.pop(current_right, set())
        root = uf.union(current_left, current_right)
        members[root] = left_members | right_members
        cluster_scores[root] = left_scores + right_scores + [score]
    diagnostics.extend(handover_records)

    groups: dict[int, list[int]] = {}
    for index in range(len(kept)):
        groups.setdefault(uf.find(index), []).append(index)

    global_tracks, cam_to_global, identity_confidence = {}, {}, {}
    matched_indices = set()
    ordered_groups = sorted(groups.values(), key=lambda group: min(kept[index].start_time for index in group))
    for global_id, group in enumerate(ordered_groups, start=1):
        members_list = [kept[index] for index in group]
        global_tracks[global_id] = _weighted_global_track(members_list, cfg.PROC_FPS)
        for tracklet in members_list:
            for source_id in tracklet.source_local_ids:
                cam_to_global[(tracklet.camera_idx, source_id)] = global_id

        cross_camera = len({item.camera_idx for item in members_list}) > 1
        scores = []
        if cross_camera:
            matched_indices.update(group)
            rootscore = cluster_scores.get(uf.find(group[0]), [])
            scores = [float(value) for value in rootscore]
        score = min(scores) if scores else None
        if score is None:
            level = "singleCamera"
        elif score >= 0.80:
            level = "high"
        elif score >= 0.70:
            level = "medium"
        else:
            level = "low"
        identity_confidence[global_id] = {"score": score, "level": level}

    return FusionResult(
        global_tracks=global_tracks,
        cam_to_global=cam_to_global,
        identity_confidence=identity_confidence,
        diagnostics=diagnostics,
        local_stitches=local_stitches,
        overlap_merges=overlap_merges,
        handover_merges=handover_merges,
        unmatched_tracklets=len(kept) - len(matched_indices),
        filtered_tracklets=len(filtered),
    )
