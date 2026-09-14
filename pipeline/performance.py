"""Per-job wall-clock timings and bounded local camera-stage cache (no video pixels)."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import time
from contextlib import contextmanager

import numpy as np
from .tracklet import AppearanceSample


class Timings:
    def __init__(self, path):
        self.path = Path(path)
        self.started = time.perf_counter()
        self.seconds = {}
        self.cache_hits = 0

    @contextmanager
    def measure(self, name):
        start = time.perf_counter()
        try:
            yield
        finally:
            self.seconds[name] = self.seconds.get(name, 0) + time.perf_counter() - start

    def save(self):
        data = {"elapsedSeconds": time.perf_counter() - self.started,
                "stageSeconds": self.seconds, "cameraCacheHits": self.cache_hits}
        self.path.write_text(json.dumps(data, indent=2))


def _fingerprint(path):
    p = Path(path).expanduser().resolve()
    stat = p.stat()
    return [str(p), stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns]


def camera_cache_key(camera, model_path, cfg):
    # Include code and library versions, not calibration or presentation settings.
    from importlib.metadata import version
    files = [Path(__file__).with_name(n) for n in
             ('detect.py', 'track.py', 'tracklet.py', 'reid_reuse.py', 'performance.py')]
    options = {k: str(getattr(cfg, k)) for k in dir(cfg)
               if k.startswith('REID_') or k in ('DEVICE','HALF','IMGSZ','CONF','IOU',
                   'PERSON_CLASS','PROC_FPS','BATCH_SIZE','MAX_DURATION_SEC','WITH_REID','TORCH_THREADS')}
    from .timing import camera_source_start
    data = {"video": _fingerprint(camera.videoPath), "model": _fingerprint(model_path),
            "reid": _fingerprint(cfg.REID_WEIGHTS) if cfg.WITH_REID else None,
            "start": camera_source_start(camera), "duration": camera.durationSec,
            "options": options, "code": [hashlib.sha256(p.read_bytes()).hexdigest() for p in files],
            "versions": {k: version(k) for k in ('torch','torchvision','ultralytics','boxmot','opencv-python')}}
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()


class CameraCache:
    def __init__(self, cfg):
        self.root = Path(cfg.WORKDIR) / 'camera-cache-v1'
        self.enabled = getattr(cfg, 'CAMERA_CACHE', True)
        self.max_bytes = getattr(cfg, 'CAMERA_CACHE_MB', 512) * 1024 * 1024

    def load(self, key):
        if not self.enabled:
            return None
        path = self.root / (key + '.json.gz')
        try:
            if time.time() - path.stat().st_mtime > 7 * 86400:
                return None
            with gzip.open(path, 'rt') as f:
                data = json.load(f)
            detection = data['detection']
            detection['dets'] = [(i,t,np.asarray(b,dtype=np.float32).reshape(-1,5)) for i,t,b in detection['dets']]
            tracks = {int(k): v for k,v in data['tracks'].items()}
            frames = {int(k): v for k,v in data['frames'].items()}
            samples = {int(k): [AppearanceSample(t,c,np.asarray(e,dtype=np.float32)) for t,c,e in v]
                       for k,v in data['samples'].items()}
            return detection, (tracks, frames, samples, data['warnings'])
        except (OSError, ValueError, KeyError, TypeError, EOFError):
            return None

    def store(self, key, detection, tracking):
        if not self.enabled:
            return
        tracks, frames, samples, warnings = tracking
        data = {'detection': detection, 'tracks': tracks, 'frames': frames, 'warnings': warnings,
                'samples': {k: [(s.time,s.confidence,s.embedding) for s in v] for k,v in samples.items()}}
        def native(value):
            if isinstance(value,np.ndarray): return value.tolist()
            if isinstance(value,np.generic): return value.item()
            raise TypeError(type(value).__name__)
        self.root.mkdir(parents=True, exist_ok=True)
        target = self.root / (key + '.json.gz')
        tmp = self.root / (key + f'.{os.getpid()}.tmp')
        try:
            with gzip.open(tmp,'wt') as f:
                json.dump(data,f,default=native,separators=(',',':'),allow_nan=False)
            os.replace(tmp,target)
            files = sorted(self.root.glob('*.json.gz'), key=lambda p:p.stat().st_mtime, reverse=True)
            total=0
            for p in files:
                total += p.stat().st_size
                if total > self.max_bytes or time.time()-p.stat().st_mtime > 7*86400:
                    p.unlink(missing_ok=True)
        except OSError as exc:
            print(f'[cache] write skipped: {exc}',flush=True)
        finally:
            tmp.unlink(missing_ok=True)
