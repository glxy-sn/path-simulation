import numpy as np
from pipeline.privacy import paint_person_mask


def test_mosaic_changes_person_pixels_and_preserves_background():
    rng = np.random.default_rng(5)
    frame = rng.integers(0,256,(100,100,3),dtype=np.uint8)
    original = frame.copy()
    mask = np.zeros((100,100),dtype=bool)
    mask[20:80,45:55] = True
    result = paint_person_mask(frame,mask)
    assert not np.array_equal(result[mask],frame[mask])
    assert np.array_equal(result[:,20],frame[:,20])
    assert np.array_equal(result[0,0],frame[0,0])
    assert np.array_equal(frame,original)
    assert np.array_equal(result[30,46],result[31,46])


def test_empty_mask_preserves_frame():
    frame = np.full((30,40,3),123,dtype=np.uint8)
    assert np.array_equal(paint_person_mask(frame,np.zeros((15,20))),frame)
