import unittest
import time
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

from models import CalibrationPreviewRequest, CameraInput
from pipeline.preview import (
    CalibrationPreviewManager,
    _CachedCamera,
    _CachedPreview,
)
from pipeline.timing import camera_source_start, camera_source_time
from pipeline.tracklet import AppearanceSample, Tracklet


def config():
    return SimpleNamespace(
        REID_MIN_SAMPLES=3,
        OVERLAP_BASE_RADIUS_M=0.6,
        OVERLAP_APPEARANCE_RADIUS_M=2.5,
        OVERLAP_MIN_SIM=0.60,
    )


def projection_config():
    return SimpleNamespace(
        PREVIEW_CACHE_TTL_SEC=60,
        REID_MIN_SAMPLES=3,
        OVERLAP_BASE_RADIUS_M=0.6,
        OVERLAP_APPEARANCE_RADIUS_M=2.5,
        OVERLAP_MIN_SIM=0.60,
    )


def preview_track(camera, local_id, position, embedding=(1.0, 0.0), samples=3, uncertainty=0.1):
    vector = np.asarray(embedding, dtype=np.float32)
    vector /= np.linalg.norm(vector)
    appearance = [AppearanceSample(float(index), 0.9, vector.copy()) for index in range(samples)]
    x, y = position
    return Tracklet(
        camera_idx=camera,
        local_track_id=local_id,
        source_local_ids={local_id},
        bbox_observations=[(5.0, 0.0, 0.0, 1.0, 2.0, 0.9)],
        floor_observations=[(5.0, x, y, 0.9)],
        appearance_samples=appearance,
        calibration_uncertainty_m=uncertainty,
    )


def camera_payload(**extra):
    value = {
        "label": "camera",
        "videoPath": "/tmp/camera.mp4",
        "imagePoints": [{"x": 0, "y": 0}] * 4,
        "planePoints": [{"x": 0, "y": 0}] * 4,
    }
    value.update(extra)
    return value


def cached_preview(camera_id="camera-1", source_time=4.0):
    return _CachedPreview(
        created_at=time.monotonic(),
        global_time=4.0,
        cameras=[
            _CachedCamera(
                camera_id=camera_id,
                label="camera",
                video_path="/tmp/camera.mp4",
                source_time=source_time,
                frame=np.zeros((120, 200, 3), dtype=np.uint8),
                width=200,
                height=120,
                detections=[],
            )
        ],
        inference_warnings=[],
    )


class PreviewAssociationTests(unittest.TestCase):
    def test_single_camera_request_is_supported(self):
        request = CalibrationPreviewRequest.model_validate(
            {
                "venue": {"widthM": 10, "heightM": 7.5},
                "cameras": [camera_payload()],
                "globalTimeSec": 4.0,
            }
        )
        self.assertEqual(len(request.cameras), 1)

    def test_single_camera_detection_skips_reid_and_has_no_embeddings(self):
        manager = CalibrationPreviewManager(config())
        manager._detector = object()
        with patch("pipeline.preview.make_tracker") as make_tracker:
            manager._load_models(needs_reid=False)
        make_tracker.assert_not_called()
        with patch(
            "pipeline.preview._boxes_from_result",
            return_value=np.asarray([[10, 20, 30, 60, 0.9]], dtype=np.float32),
        ):
            detections = manager._build_single_camera_detections(object())
        self.assertEqual(len(detections), 1)
        self.assertEqual(detections[0].foot_pixel, (20.0, 60.0))
        self.assertEqual(detections[0].appearance_samples, [])

    def test_reproject_echoes_exact_camera_and_homography_identity(self):
        manager = CalibrationPreviewManager(projection_config())
        manager._cache["token"] = cached_preview()
        camera = CameraInput.model_validate(
            camera_payload(
                cameraId="camera-1",
                calibrationFingerprint="homography-v2",
                frameWidth=200,
                frameHeight=120,
            )
        )
        evaluation = SimpleNamespace(
            warnings=[],
            uncertainty_m=0.1,
            pixel_to_world=np.eye(3, dtype=np.float64),
        )
        with patch("pipeline.preview.evaluate_calibration", return_value=evaluation):
            response = manager._reproject(
                "token",
                SimpleNamespace(widthM=10.0, heightM=7.5),
                [camera],
            )
        output = response.cameras[0]
        self.assertEqual(output.cameraId, "camera-1")
        self.assertEqual(output.videoPath, "/tmp/camera.mp4")
        self.assertEqual(output.calibrationFingerprint, "homography-v2")
        self.assertEqual((output.frameWidth, output.frameHeight), (200, 120))

    def test_reproject_rejects_cached_frame_from_another_camera(self):
        manager = CalibrationPreviewManager(projection_config())
        manager._cache["token"] = cached_preview(camera_id="camera-1")
        camera = CameraInput.model_validate(camera_payload(cameraId="camera-2"))
        with self.assertRaisesRegex(ValueError, "pasangan kamera preview berubah"):
            manager._reproject(
                "token",
                SimpleNamespace(widthM=10.0, heightM=7.5),
                [camera],
            )

    def test_reproject_rejects_cached_frame_from_another_timestamp(self):
        manager = CalibrationPreviewManager(projection_config())
        manager._cache["token"] = cached_preview(source_time=3.0)
        camera = CameraInput.model_validate(camera_payload(cameraId="camera-1"))
        with self.assertRaisesRegex(ValueError, "waktu frame preview berubah"):
            manager._reproject(
                "token",
                SimpleNamespace(widthM=10.0, heightM=7.5),
                [camera],
            )

    def test_same_appearance_and_position_is_accepted(self):
        manager = CalibrationPreviewManager(config())
        records, accepted = manager._associate(
            [preview_track(0, 1, (2.0, 3.0))],
            [preview_track(1, 7, (2.1, 3.0))],
        )
        self.assertEqual(len(accepted), 1)
        self.assertEqual(records[0].decision, "accepted")
        self.assertEqual(records[0].reason, "hungarianMatch")

    def test_friend_fix_uses_wider_gate_for_same_appearance(self):
        manager = CalibrationPreviewManager(config())
        records, accepted = manager._associate(
            [preview_track(0, 1, (0.0, 0.0))],
            [preview_track(1, 7, (1.8, 0.0))],
        )
        self.assertEqual(len(accepted), 1)
        self.assertEqual(records[0].uncertaintyGateM, 2.5)

    def test_geometry_and_embedding_gates_are_reported(self):
        manager = CalibrationPreviewManager(config())
        records, accepted = manager._associate(
            [preview_track(0, 1, (0.0, 0.0))],
            [
                preview_track(1, 2, (10.0, 0.0)),
                preview_track(1, 3, (0.0, 0.0), samples=2),
            ],
        )
        self.assertEqual(accepted, [])
        self.assertEqual(
            {record.reason for record in records},
            {"distanceOutsideUncertaintyGate", "insufficientEmbeddingSamples"},
        )

    def test_hungarian_keeps_preview_one_to_one(self):
        manager = CalibrationPreviewManager(config())
        records, accepted = manager._associate(
            [preview_track(0, 1, (0.0, 0.0)), preview_track(0, 2, (0.1, 0.0))],
            [preview_track(1, 3, (0.05, 0.0))],
        )
        self.assertEqual(len(accepted), 1)
        self.assertEqual(sum(record.decision == "accepted" for record in records), 1)
        self.assertIn("notSelectedByHungarian", {record.reason for record in records})


class CameraOffsetTests(unittest.TestCase):
    def test_legacy_camera_defaults_to_zero_offset(self):
        camera = CameraInput.model_validate(camera_payload())
        self.assertEqual(camera.timeOffsetSec, 0.0)
        self.assertEqual(camera_source_start(camera), 0.0)

    def test_positive_offset_reads_later_source_time(self):
        camera = CameraInput.model_validate(
            camera_payload(startSec=12.5, timeOffsetSec=2.4)
        )
        self.assertAlmostEqual(camera_source_start(camera), 14.9)
        self.assertAlmostEqual(camera_source_time(camera, 20.0), 22.4)


if __name__ == "__main__":
    unittest.main()
