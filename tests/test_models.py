import unittest

from models import JobResult


class ModelCompatibilityTests(unittest.TestCase):
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
        self.assertIsNone(result.identityQuality)
        self.assertIsNone(result.artifacts.fusionDiagnostics)


if __name__ == "__main__":
    unittest.main()
