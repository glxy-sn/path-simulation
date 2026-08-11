"""Tracklet representation and bounded, anonymous appearance sampling."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np


@dataclass(frozen=True)
class AppearanceSample:
    time: float
    confidence: float
    embedding: np.ndarray = field(repr=False, compare=False)


class TrackAppearanceSampler:
    """Keep the strongest sample per time bin and at most N spread-out samples."""

    def __init__(self, bin_seconds: float = 1.0, max_samples: int = 12, min_confidence: float = 0.5):
        self.bin_seconds = max(float(bin_seconds), 1e-6)
        self.max_samples = max(int(max_samples), 1)
        self.min_confidence = float(min_confidence)
        self._bins: dict[int, AppearanceSample] = {}

    def add(self, time: float, confidence: float, embedding) -> bool:
        if confidence < self.min_confidence:
            return False
        vector = np.asarray(embedding, dtype=np.float32).reshape(-1)
        if vector.size == 0 or not np.isfinite(vector).all():
            return False
        norm = float(np.linalg.norm(vector))
        if norm <= 1e-12:
            return False
        sample = AppearanceSample(float(time), float(confidence), vector / norm)
        key = int(np.floor(float(time) / self.bin_seconds))
        old = self._bins.get(key)
        if old is None or sample.confidence > old.confidence:
            self._bins[key] = sample
            return True
        return False

    def samples(self) -> list[AppearanceSample]:
        ordered = [self._bins[key] for key in sorted(self._bins)]
        if len(ordered) <= self.max_samples:
            return ordered
        indices = np.linspace(0, len(ordered) - 1, self.max_samples).round().astype(int)
        return [ordered[int(index)] for index in indices]


@dataclass
class Tracklet:
    camera_idx: int
    local_track_id: int
    source_local_ids: set[int]
    bbox_observations: list[tuple[float, float, float, float, float, float]]
    floor_observations: list[tuple[float, float, float, float]]
    appearance_samples: list[AppearanceSample]
    calibration_uncertainty_m: float = 0.05

    @property
    def key(self) -> tuple[int, int]:
        return self.camera_idx, self.local_track_id

    @property
    def start_time(self) -> float:
        return min(o[0] for o in self.floor_observations)

    @property
    def end_time(self) -> float:
        return max(o[0] for o in self.floor_observations)

    @property
    def duration(self) -> float:
        return self.end_time - self.start_time

    @property
    def start_position(self) -> tuple[float, float]:
        first = min(self.floor_observations, key=lambda value: value[0])
        return first[1], first[2]

    @property
    def end_position(self) -> tuple[float, float]:
        last = max(self.floor_observations, key=lambda value: value[0])
        return last[1], last[2]

    def merged_with(self, other: "Tracklet") -> "Tracklet":
        if self.camera_idx != other.camera_idx:
            raise ValueError("local stitching hanya boleh menggabungkan satu kamera")
        return Tracklet(
            camera_idx=self.camera_idx,
            local_track_id=min(self.local_track_id, other.local_track_id),
            source_local_ids=self.source_local_ids | other.source_local_ids,
            bbox_observations=sorted(self.bbox_observations + other.bbox_observations),
            floor_observations=sorted(self.floor_observations + other.floor_observations),
            appearance_samples=_spread_samples(
                self.appearance_samples + other.appearance_samples, 12
            ),
            calibration_uncertainty_m=max(
                self.calibration_uncertainty_m, other.calibration_uncertainty_m
            ),
        )


def _spread_samples(samples: list[AppearanceSample], maximum: int) -> list[AppearanceSample]:
    if not samples:
        return []
    best_by_second: dict[int, AppearanceSample] = {}
    for sample in samples:
        key = int(np.floor(sample.time))
        old = best_by_second.get(key)
        if old is None or sample.confidence > old.confidence:
            best_by_second[key] = sample
    ordered = [best_by_second[key] for key in sorted(best_by_second)]
    if len(ordered) <= maximum:
        return ordered
    indices = np.linspace(0, len(ordered) - 1, maximum).round().astype(int)
    return [ordered[int(index)] for index in indices]


def appearance_similarity(a: Tracklet, b: Tracklet, minimum_samples: int = 3) -> float | None:
    """Median of the three strongest pairwise cosine similarities."""
    if len(a.appearance_samples) < minimum_samples or len(b.appearance_samples) < minimum_samples:
        return None
    similarities = [
        float(np.dot(left.embedding, right.embedding))
        for left in a.appearance_samples
        for right in b.appearance_samples
    ]
    if len(similarities) < 3:
        return None
    top = sorted(similarities, reverse=True)[:3]
    return float(np.median(top))
