import unittest
from types import SimpleNamespace

import numpy as np

from pipeline.fuse import fuse_tracklets
from pipeline.tracklet import AppearanceSample, Tracklet


def cfg():
    return SimpleNamespace(
        PROC_FPS=5.0,
        REID_MIN_SAMPLES=3,
        LOCAL_STITCH_MAX_GAP_SEC=2.0,
        LOCAL_STITCH_MAX_DIST_M=1.5,
        LOCAL_STITCH_MAX_SPEED_MPS=2.0,
        LOCAL_STITCH_MIN_SIM=.70,
        OVERLAP_BASE_RADIUS_M=.6,
        OVERLAP_APPEARANCE_RADIUS_M=2.5,
        OVERLAP_MIN_SEC=1.0,
        OVERLAP_MIN_SIM=.60,
        WITH_APP_FUSION=True,
        HANDOVER_MAX_GAP_SEC=15.0,
        HANDOVER_MAX_SPEED_MPS=2.0,
        HANDOVER_MIN_SIM=.68,
        MIN_TRACK_SEC=1.5,
        MIN_TRACK_POINTS=3,
    )


def track(camera, local_id, times, positions, embedding=(1.0, 0.0), samples=3):
    vector = np.asarray(embedding, dtype=np.float32)
    vector /= np.linalg.norm(vector)
    appearances = [AppearanceSample(times[min(i, len(times) - 1)], .9, vector.copy()) for i in range(samples)]
    floor = [(t, x, y, .9) for t, (x, y) in zip(times, positions)]
    boxes = [(t, x, y, x + 1, y + 2, .9) for t, (x, y) in zip(times, positions)]
    return Tracklet(camera, local_id, {local_id}, boxes, floor, appearances, .1)


class FusionTests(unittest.TestCase):
    def test_local_fragmentation_is_stitched_before_filter(self):
        first = track(0, 1, [0, 1, 2], [(0, 0), (1, 0), (2, 0)])
        second = track(0, 2, [2.5, 3.5, 4.5], [(2.4, 0), (3.4, 0), (4.4, 0)])
        result = fuse_tracklets([first, second], cfg())
        self.assertEqual(result.local_stitches, 1)
        self.assertEqual(len(result.global_tracks), 1)
        self.assertEqual(result.cam_to_global[(0, 1)], result.cam_to_global[(0, 2)])

    def test_overlap_same_person_merges(self):
        a = track(0, 1, [0, 1, 2, 3], [(0, 0), (1, 0), (2, 0), (3, 0)])
        b = track(1, 4, [0, 1, 2, 3], [(.1, 0), (1.1, 0), (2.1, 0), (3.1, 0)])
        result = fuse_tracklets([a, b], cfg())
        self.assertEqual(result.overlap_merges, 1)
        self.assertEqual(len(result.global_tracks), 1)

    def test_friend_fix_allows_appearance_match_inside_wider_cross_camera_gate(self):
        a = track(0, 1, [0, 1, 2, 3], [(0, 0), (1, 0), (2, 0), (3, 0)])
        b = track(1, 4, [0, 1, 2, 3], [(1.8, 0), (2.8, 0), (3.8, 0), (4.8, 0)])
        result = fuse_tracklets([a, b], cfg())
        self.assertEqual(result.overlap_merges, 1)
        accepted = [item for item in result.diagnostics if item["decision"] == "accepted"]
        self.assertEqual(accepted[0]["associationBasis"], "appearanceAndGeometry")

    def test_nearby_people_with_different_appearance_do_not_merge(self):
        a = track(0, 1, [0, 1, 2], [(0, 0), (1, 0), (2, 0)], (1, 0))
        b = track(1, 2, [0, 1, 2], [(.05, 0), (1.05, 0), (2.05, 0)], (0, 1))
        result = fuse_tracklets([a, b], cfg())
        self.assertEqual(result.overlap_merges, 0)
        self.assertEqual(len(result.global_tracks), 2)

    def test_valid_handover_merges(self):
        a = track(0, 1, [0, 1, 2], [(0, 0), (1, 0), (2, 0)])
        b = track(1, 2, [3, 4, 5], [(3, 0), (4, 0), (5, 0)])
        result = fuse_tracklets([a, b], cfg())
        self.assertEqual(result.handover_merges, 1)
        self.assertEqual(len(result.global_tracks), 1)

    def test_impossible_speed_and_long_gap_are_rejected(self):
        base = track(0, 1, [0, 1, 2], [(0, 0), (1, 0), (2, 0)])
        fast = track(1, 2, [3, 4, 5], [(20, 0), (21, 0), (22, 0)])
        late = track(2, 3, [20, 21, 22], [(-20, 0), (-19, 0), (-18, 0)])
        result = fuse_tracklets([base, fast, late], cfg())
        reasons = {item["reason"] for item in result.diagnostics}
        self.assertIn("impossibleSpeed", reasons)
        self.assertIn("gapTooLong", reasons)
        self.assertEqual(len(result.global_tracks), 3)

    def test_insufficient_embedding_never_auto_merges(self):
        a = track(0, 1, [0, 1, 2], [(0, 0), (1, 0), (2, 0)], samples=2)
        b = track(1, 2, [0, 1, 2], [(0, 0), (1, 0), (2, 0)], samples=2)
        result = fuse_tracklets([a, b], cfg())
        self.assertEqual(len(result.global_tracks), 2)
        self.assertIn("insufficientEmbeddingSamples", {d["reason"] for d in result.diagnostics})

    def test_three_camera_one_to_many_conflict_is_rejected(self):
        a = track(0, 1, [0, 1, 2], [(0, 0), (1, 0), (2, 0)], (1, 0))
        b = track(1, 2, [3, 4, 5], [(3, .2), (4, .2), (5, .2)], (.8, .6))
        c = track(2, 3, [3, 4, 5], [(3, -.2), (4, -.2), (5, -.2)], (.8, -.6))
        result = fuse_tracklets([a, b, c], cfg())
        self.assertEqual(result.handover_merges, 1)
        self.assertEqual(len(result.global_tracks), 2)
        self.assertIn("oneToManyConflict", {d["reason"] for d in result.diagnostics})

    def test_three_camera_transitive_overlap_bridge_is_rejected(self):
        a = track(0, 1, [0, 1, 2], [(0, 0), (1, 0), (2, 0)], (1, 0))
        b = track(1, 2, [0, 1, 2], [(0, .1), (1, .1), (2, .1)], (.8, .6))
        c = track(2, 3, [0, 1, 2], [(0, -.1), (1, -.1), (2, -.1)], (.8, -.6))
        result = fuse_tracklets([a, b, c], cfg())
        self.assertEqual(result.overlap_merges, 1)
        self.assertEqual(len(result.global_tracks), 2)
        self.assertIn("transitiveAppearanceConflict", {d["reason"] for d in result.diagnostics})

    def test_filtered_track_has_no_global_or_render_mapping(self):
        short = track(0, 1, [0, .2, .4], [(0, 0), (.2, 0), (.4, 0)])
        result = fuse_tracklets([short], cfg())
        self.assertEqual(result.filtered_tracklets, 1)
        self.assertEqual(result.global_tracks, {})
        self.assertNotIn((0, 1), result.cam_to_global)


if __name__ == "__main__":
    unittest.main()
