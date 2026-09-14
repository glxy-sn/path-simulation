import unittest

from model_registry import DETECTION_MODELS, DEFAULT_DETECTION_MODEL_ID, resolve_detection_model
from models import JobResult


class ModelCompatibilityTests(unittest.TestCase):
    def test_detection_model_allowlist_has_only_installed_yolo11s_weights(self):
        self.assertEqual(
            set(DETECTION_MODELS),
            {"yolo11s-base", "yolo11s-finetuned-stage2-caviar"},
        )
        self.assertEqual(DEFAULT_DETECTION_MODEL_ID, "yolo11s-base")
        self.assertTrue(resolve_detection_model(DEFAULT_DETECTION_MODEL_ID).path.is_file())
        self.assertTrue(resolve_detection_model("yolo11s-base").path.is_file())

    def test_detection_model_allowlist_rejects_arbitrary_paths(self):
        with self.assertRaisesRegex(ValueError, "Model deteksi tidak dikenal"):
            resolve_detection_model("/tmp/other-weights.pt")

    def test_old_result_without_optional_identity_fields_still_decodes(self):
        result = JobResult.model_validate(
            {
                "jobId": "legacy",
                "venue": {"widthM": 10, "heightM": 7.5},
                "summary": {"totalVisitors": 0, "avgDwellSeconds": 0, "peakOccupancy": 0, "captureRate": 0},
                "zones": [],
                "stopPoints": [],
                "occupancy": [],
                "artifacts": {},
            }
        )
        self.assertEqual(result.blobs, [])
        self.assertEqual(result.paths, [])
        self.assertEqual(result.observations, [])
        self.assertIsNone(result.identityQuality)
        self.assertIsNone(result.artifacts.fusionDiagnostics)


if __name__ == "__main__":
    unittest.main()
