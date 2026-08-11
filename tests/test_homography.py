import unittest
from types import SimpleNamespace

import numpy as np

from models import CalibrationInput, CameraInput, Point
from pipeline.homography import evaluate_calibration, project_points


def config():
    return SimpleNamespace(
        CALIBRATION_INLIER_THRESHOLD_M=0.25,
        CALIBRATION_WARN_INLIER_RATIO=0.75,
        CALIBRATION_WARN_MEDIAN_M=0.15,
        CALIBRATION_WARN_P95_M=0.40,
        CALIBRATION_WARN_IMAGE_COVERAGE=0.10,
        CALIBRATION_WARN_PLANE_COVERAGE=0.15,
    )


def camera(image, plane, matrix=None):
    calibration = None
    if matrix is not None:
        calibration = CalibrationInput(
            homographyNormToWorld=np.asarray(matrix).tolist(),
            inlierMask=[True] * len(image),
            medianErrorM=0,
            p95ErrorM=0,
            inliers=len(image),
            points=len(image),
        )
    return CameraInput(
        label="C1",
        videoPath="unused.mp4",
        imagePoints=[Point(x=x, y=y) for x, y in image],
        planePoints=[Point(x=x, y=y) for x, y in plane],
        calibration=calibration,
    )


class HomographyTests(unittest.TestCase):
    def test_normalized_homography_is_resolution_invariant(self):
        points = [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)]
        H_norm = np.diag([10.0, 7.5, 1.0])
        value = camera(points, points, H_norm)
        first = evaluate_calibration(value, 4608, 2592, 10, 7.5, config())
        second = evaluate_calibration(value, 2304, 1296, 10, 7.5, config())
        projected_first = project_points(first.pixel_to_world, [[2304, 1296]])[0]
        projected_second = project_points(second.pixel_to_world, [[1152, 648]])[0]
        np.testing.assert_allclose(projected_first, projected_second, atol=1e-6)
        np.testing.assert_allclose(projected_first, [5.0, 3.75], atol=1e-6)

    def test_legacy_ransac_rejects_outlier(self):
        image = [
            (0.1, 0.1), (0.5, 0.1), (0.9, 0.1), (0.1, 0.5),
            (0.9, 0.5), (0.1, 0.9), (0.5, 0.9), (0.9, 0.9),
        ]
        plane = list(image)
        plane[-1] = (0.05, 0.95)
        result = evaluate_calibration(camera(image, plane), 1000, 800, 10, 8, config())
        self.assertTrue(result.legacy_calibration)
        self.assertEqual(sum(result.inlier_mask), 7)
        self.assertFalse(result.inlier_mask[-1])

    def test_malformed_and_singular_matrix_are_invalid(self):
        points = [(0, 0), (1, 0), (1, 1), (0, 1)]
        with self.assertRaisesRegex(ValueError, "3x3"):
            evaluate_calibration(camera(points, points, [[1, 0], [0, 1]]), 100, 100, 1, 1, config())
        with self.assertRaisesRegex(ValueError, "singular"):
            evaluate_calibration(camera(points, points, np.zeros((3, 3))), 100, 100, 1, 1, config())

    def test_all_quality_warning_thresholds_are_reported(self):
        image = [(0.01, 0.01), (0.05, 0.01), (0.05, 0.05), (0.01, 0.05)]
        plane = [(0.01, 0.01), (0.05, 0.01), (0.05, 0.05), (0.01, 0.05)]
        shifted = np.array([[10, 0, 2], [0, 10, 2], [0, 0, 1]], dtype=float)
        result = evaluate_calibration(camera(image, plane, shifted), 100, 100, 10, 10, config())
        expected = {
            "inlierRatioBelow75Percent",
            "medianErrorAbove0.15m",
            "p95ErrorAbove0.40m",
            "cameraPointCoverageBelow10Percent",
            "floorPointCoverageBelow15Percent",
        }
        self.assertTrue(expected.issubset(set(result.warnings)))


if __name__ == "__main__":
    unittest.main()
