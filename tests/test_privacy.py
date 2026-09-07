import numpy as np
from pipeline.privacy import paint_person_mask


def test_silhouette_is_opaque_and_background_is_preserved():
    frame = np.full((100, 100, 3), 255, dtype=np.uint8)
    mask = np.zeros((100, 100), dtype=bool)
    mask[20:80, 45:55] = True
    result = paint_person_mask(frame, mask)
    assert np.all(result[mask] == (180, 130, 80))
    assert np.all(result[20:80, 25] == 255)  # Not a bounding-box censor.
    assert np.all(result[0, 0] == 255)
    assert np.all(frame == 255)


def test_empty_mask_preserves_frame():
    frame = np.full((30, 40, 3), 123, dtype=np.uint8)
    assert np.array_equal(paint_person_mask(frame, np.zeros((15, 20))), frame)
