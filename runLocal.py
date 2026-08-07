"""
Jalankan satu job langsung dari CLI tanpa server (untuk debug/uji pipeline).

Contoh:
  python run_local.py job.json

job.json = JobRequest, contoh:
{
  "venue": {"widthM": 20, "heightM": 15, "name": "Pujasera Kampus", "type": "pujasera"},
  "mode": "lengkap",
  "options": {"renderVideos": true},
  "cameras": [
    {
      "label": "Pintu Masuk",
      "videoPath": "/abs/path/cam_entrance.mp4",
      "imagePoints": [{"x":0.12,"y":0.80},{"x":0.88,"y":0.82},{"x":0.80,"y":0.30},{"x":0.20,"y":0.30}],
      "planePoints": [{"x":0.10,"y":0.90},{"x":0.90,"y":0.90},{"x":0.90,"y":0.55},{"x":0.10,"y":0.55}]
    }
  ]
}
"""
import sys
import json
import time

from models import JobRequest
from pipeline.run import run_job


def main():
    if len(sys.argv) < 2:
        print("usage: python run_local.py <job.json>")
        sys.exit(1)

    with open(sys.argv[1]) as f:
        req = JobRequest(**json.load(f))

    last = [0.0, ""]

    def progress(stage, fraction):
        if stage != last[1] or fraction - last[0] > 0.05:
            print(f"[{stage:10s}] {int(fraction*100):3d}%")
            last[0], last[1] = fraction, stage

    t0 = time.time()
    result = run_job("local", req, progress)
    print(f"\nselesai dalam {time.time()-t0:.1f}s\n")
    print(result.model_dump_json(indent=2))


if __name__ == "__main__":
    main()