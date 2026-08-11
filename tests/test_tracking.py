import unittest
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

from pipeline.track import extract_embeddings_once, track_from_dets
from pipeline.tracklet import TrackAppearanceSampler


class FakeModel:
    def __init__(self):
        self.calls = 0
        self.last = None

    def get_features(self, boxes, frame):
        self.calls += 1
        self.last = np.asarray([[1.0, 0.0], [0.0, 1.0]], dtype=np.float32)[:len(boxes)]
        return self.last


class FakeTracker:
    def __init__(self, fail=False):
        self.model = FakeModel()
        self.fail = fail
        self.received = None

    def update(self, dets, frame, embs=None):
        if self.fail:
            raise ValueError("tracker exploded")
        self.received = embs
        return np.asarray([[10, 10, 20, 30, 7, 0.9, 0, 1]], dtype=np.float32)


class FakeCapture:
    def __init__(self, _path):
        self.frames = [np.zeros((40, 40, 3), dtype=np.uint8)]

    def isOpened(self):
        return True

    def read(self):
        return (True, self.frames.pop(0)) if self.frames else (False, None)

    def release(self):
        pass

    def set(self, *_args):
        return True

    def get(self, *_args):
        return 0


def cfg():
    return SimpleNamespace(
        WITH_REID=True,
        REID_SAMPLE_BIN_SEC=1.0,
        REID_MAX_SAMPLES=12,
        REID_SAMPLE_CONF=0.5,
    )


class TrackingTests(unittest.TestCase):
    def test_feature_batch_is_computed_once(self):
        tracker = FakeTracker()
        dets = np.asarray([[0, 0, 10, 10, .8, 0], [10, 10, 20, 20, .9, 0]], dtype=np.float32)
        filtered, embeddings, indices, warnings = extract_embeddings_once(
            tracker, dets, np.zeros((30, 30, 3), dtype=np.uint8)
        )
        self.assertEqual(tracker.model.calls, 1)
        self.assertEqual(len(filtered), 2)
        self.assertEqual(indices, [0, 1])
        self.assertEqual(warnings, [])
        self.assertIs(embeddings, tracker.model.last)

    @patch("pipeline.track.seek_accurate", lambda *_args: None)
    @patch("pipeline.track.cv2.VideoCapture", FakeCapture)
    def test_det_ind_attaches_correct_embedding_to_track(self):
        tracker = FakeTracker()
        boxes = np.asarray([[0, 0, 10, 10, .8], [10, 10, 20, 30, .9]], dtype=np.float32)
        _tracks, _frames, samples, _warnings = track_from_dets(
            "unused", [(0, 0.0, boxes)], cfg(), tracker=tracker
        )
        self.assertIs(tracker.received, tracker.model.last)
        np.testing.assert_allclose(samples[7][0].embedding, [0, 1])

    @patch("pipeline.track.seek_accurate", lambda *_args: None)
    @patch("pipeline.track.cv2.VideoCapture", FakeCapture)
    def test_tracker_errors_are_not_silenced(self):
        boxes = np.asarray([[0, 0, 10, 10, .8], [10, 10, 20, 30, .9]], dtype=np.float32)
        with self.assertRaisesRegex(RuntimeError, "frame 0.*tracker exploded"):
            track_from_dets("unused", [(0, 0.0, boxes)], cfg(), tracker=FakeTracker(fail=True))

    def test_sampler_keeps_best_per_second_and_maximum_twelve(self):
        sampler = TrackAppearanceSampler(max_samples=12, min_confidence=.5)
        sampler.add(0.1, .6, [1, 0])
        sampler.add(0.8, .9, [0, 1])
        for second in range(1, 20):
            sampler.add(second + .1, .8, [1, second + 1])
        samples = sampler.samples()
        self.assertEqual(len(samples), 12)
        self.assertEqual(samples[0].confidence, .9)
        self.assertGreater(samples[-1].time, 18)


if __name__ == "__main__":
    unittest.main()
