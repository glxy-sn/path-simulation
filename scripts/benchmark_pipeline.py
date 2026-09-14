"""Run a short, reproducible pipeline benchmark from an existing local job.json."""
import argparse
import json
import os
from pathlib import Path
import sys
import time

os.environ.setdefault('MTL_DEBUG_LAYER','0')
os.environ.setdefault('MTL_SHADER_VALIDATION','0')
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--job',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--duration',type=float,default=4)
    parser.add_argument('--label',default='benchmark')
    parser.add_argument('--no-render',action='store_true')
    parser.add_argument('--no-cache',action='store_true')
    args=parser.parse_args()
    if args.duration<=0 or args.label in ('.','..') or Path(args.label).name!=args.label:
        parser.error('Use a positive duration and a plain directory name for --label')
    from config import Config
    from models import JobRequest
    from pipeline.run import run_job
    payload=json.loads(args.job.read_text())
    for camera in payload['cameras']:
        previous=camera.get('durationSec')
        camera['durationSec']=min(previous,args.duration) if previous and previous>0 else args.duration
    request=JobRequest(**payload)
    request.options.renderVideos=not args.no_render
    Config.WORKDIR=args.output.expanduser().resolve()
    Config.CAMERA_CACHE=not args.no_cache
    directory=Config.WORKDIR/args.label
    if directory.exists():
        parser.error('Output label already exists. Choose a new label to preserve prior measurements.')
    started=time.perf_counter()
    result=run_job(args.label,request,lambda *_:None)
    (directory/'result.json').write_text(result.model_dump_json())
    metadata={'seconds':time.perf_counter()-started,'durationSec':args.duration,'cameras':len(request.cameras),
              'renderVideos':request.options.renderVideos,'imgsz':Config.IMGSZ,'fps':Config.PROC_FPS,
              'reidDevice':Config.REID_DEVICE,'torchThreads':Config.TORCH_THREADS,
              'reidRefreshSec':Config.REID_REFRESH_SEC,'summary':result.summary.model_dump()}
    (directory/'benchmark.json').write_text(json.dumps(metadata,indent=2))
    print(json.dumps(metadata,indent=2))


if __name__=='__main__':
    main()
