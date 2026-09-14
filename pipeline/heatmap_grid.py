"""Bounded heatmap payload from all fused trajectories, before UI downsampling."""
import math


def build_heatmap_grid(tracks, venue, cfg, width=56, height=42):
    traffic = [0.0] * (width * height)
    time_spent = [0.0] * (width * height)
    interval = 1.0 / max(float(cfg.PROC_FPS), 1e-6)
    observations = 0
    for track in tracks.values():
        visited = set()
        for t, x, y in track:
            if not all(math.isfinite(float(v)) for v in (t,x,y)):
                continue
            column = min(width-1,max(0,int(x/venue.widthM*width)))
            row = min(height-1,max(0,int(y/venue.heightM*height)))
            index = row*width+column
            visited.add(index)
            time_spent[index] += interval
            observations += 1
        for index in visited:
            traffic[index] += 1
    return dict(width=width,height=height,footTraffic=traffic,timeSpent=time_spent,
                trackCount=len(tracks),observationCount=observations)
