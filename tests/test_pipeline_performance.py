from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import cv2
import numpy as np
import pytest

from pipeline.performance import CameraCache
from pipeline.reid_reuse import DescriptorReuse
from pipeline.render import TrailRenderer
from pipeline.tracklet import AppearanceSample
from pipeline.video_writer import VideoWriter


def test_camera_cache_roundtrip_and_corruption(tmp_path):
    cache = CameraCache(SimpleNamespace(WORKDIR=tmp_path,CAMERA_CACHE=True,CAMERA_CACHE_MB=1))
    det = {'dets':[(3,.2,np.asarray([[1,2,3,4,.9]],dtype=np.float32))]}
    tracking = ({7:[[.2,1,2,3,4,.9]]},{3:[[7,1,2,3,4,.9]]},
                {7:[AppearanceSample(.2,.9,np.array([.6,.8],dtype=np.float32))]},[])
    cache.store('a',det,tracking)
    restored = cache.load('a')
    assert restored[1][1][3][0][0] == 7
    np.testing.assert_array_equal(restored[0]['dets'][0][2],det['dets'][0][2])
    np.testing.assert_array_equal(restored[1][2][7][0].embedding,tracking[2][7][0].embedding)
    (cache.root/'a.json.gz').write_bytes(b'broken')
    assert cache.load('a') is None


def test_incremental_trail_only_draws_new_segments():
    obs = {1:[(0,0,0),(1,1,1),(2,2,2)]}
    trail = TrailRenderer(obs,SimpleNamespace(widthM=3,heightM=3),30,30,np.zeros((30,30,3),np.uint8))
    with patch('pipeline.render.cv2.line',wraps=cv2.line) as line:
        trail.advance(0)
        trail.advance(1)
        trail.advance(1.5)
        trail.advance(2)
        trail.advance(3)
        assert line.call_count == 2
    assert trail.positions[1] == 3


def test_encoder_publishes_playable_video_and_not_partial_failure(tmp_path):
    dest = tmp_path/'video.mp4'
    writer = VideoWriter(dest,5,(64,64))
    for i in range(5): writer.write(np.full((64,64,3),i*30,np.uint8))
    writer.release()
    cap = cv2.VideoCapture(str(dest))
    assert int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) == 5
    ok,frame=cap.read()
    cap.release()
    assert ok and frame.shape[:2] == (64,64)
    failed = tmp_path/'failed.mp4'
    with pytest.raises(ValueError):
        writer = VideoWriter(failed,5,(64,64))
        try:
            writer.write(np.zeros((64,64,3),np.uint8))
            raise ValueError('segmentation failed')
        finally:
            writer.release()
    assert not failed.exists()


def test_reid_reuse_refreshes_and_rejects_ambiguous_boxes():
    class Model:
        calls=0
        def get_features(self,boxes,frame):
            self.calls+=len(boxes)
            return np.tile([1.,0.],(len(boxes),1))
    model=Model()
    reuse=DescriptorReuse(.5)
    boxes=np.array([[0,0,10,10]],dtype=np.float32)
    reuse.features(model,boxes,None,0)
    reuse.features(model,boxes,None,.2)
    assert model.calls == 1
    reuse.features(model,boxes,None,.6)
    assert model.calls == 2
    reuse.features(model,np.vstack([boxes,boxes]),None,.7)
    assert model.calls == 4


def test_streaming_detection_keeps_order_and_skips_unused_frame_retrieval():
    from pipeline.detect import detect_video
    class Capture:
        def __init__(self): self.pos=0; self.reads=0; self.grabs=0; self.closed=False
        def isOpened(self): return True
        def get(self,key):
            return {cv2.CAP_PROP_FPS:10,cv2.CAP_PROP_FRAME_COUNT:10,
                    cv2.CAP_PROP_FRAME_WIDTH:4,cv2.CAP_PROP_FRAME_HEIGHT:4}.get(key,0)
        def read(self):
            self.reads+=1
            frame=np.full((4,4,3),self.pos,np.uint8)
            self.pos+=1
            return True,frame
        def grab(self): self.grabs+=1; self.pos+=1; return True
        def release(self): self.closed=True
    capture=Capture()
    seen=[]
    class Model:
        def predict(self,frames,**kwargs):
            assert len(frames)<=2
            return [SimpleNamespace(boxes=None) for _ in frames]
    cfg=SimpleNamespace(PROC_FPS=5,BATCH_SIZE=2,IMGSZ=32,CONF=.1,IOU=.7,PERSON_CLASS=0,DEVICE='cpu')
    def consume(batch,frames):
        seen.extend((fi,int(frame[0,0,0])) for (fi,_,_),frame in zip(batch,frames))
    with patch('pipeline.detect.cv2.VideoCapture',return_value=capture):
        result=detect_video(Model(),'unused',cfg,duration_sec=1,on_batch=consume)
    assert seen == [(0,0),(2,2),(4,4),(6,6),(8,8)]
    assert len(result['dets'])==5 and capture.reads==5 and capture.grabs==5 and capture.closed


def test_cache_key_changes_for_input_settings_but_not_calibration(tmp_path):
    from pipeline.performance import camera_cache_key
    video=tmp_path/'input.mp4'
    model=tmp_path/'model.pt'
    video.write_bytes(b'video')
    model.write_bytes(b'weights')
    camera=SimpleNamespace(videoPath=str(video),startSec=0,durationSec=3,timeOffsetSec=0,calibration='one')
    cfg=SimpleNamespace(WITH_REID=False,IMGSZ=1920,PROC_FPS=5)
    first=camera_cache_key(camera,model,cfg)
    camera.calibration='two'
    assert camera_cache_key(camera,model,cfg)==first
    cfg.IMGSZ=1280
    assert camera_cache_key(camera,model,cfg)!=first
    cfg.IMGSZ=1920
    video.write_bytes(b'changed video')
    assert camera_cache_key(camera,model,cfg)!=first


def test_interval_index_matches_exhaustive_candidates():
    from pipeline.fuse import _TimeIndex
    tracks=[SimpleNamespace(start_time=float(i),end_time=float(i)+d) for i,d in
            [(0,1),(2,50),(3,1),(5,2),(20,1),(60,1)]]
    index=_TimeIndex(tracks)
    for start,end in [(0,0),(1,2),(7,8),(21,30),(55,65)]:
        expected={i for i,t in enumerate(tracks) if t.start_time<=end and t.end_time>=start}
        assert {i for i,_ in index.query(start,end)}==expected
