
import numpy as np


class _UnionFind:
    def __init__(self, n):
        self.p = list(range(n))

    def find(self, x):
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]
            x = self.p[x]
        return x

    def union(self, a, b):
        self.p[self.find(a)] = self.find(b)


def fuse_tracks(cam_floor, cfg):
    """
    cam_floor: list per kamera berisi dict track_id -> list[(t, x_m, y_m)]
    Return:
      global_tracks: dict gid(int) -> list[(t, x_m, y_m)]  (posisi dirata-rata di zona overlap)
      cam_to_global: dict (cam_idx, track_id) -> gid   (untuk render overlay)
    """
    fps = cfg.PROC_FPS
    tracks = []  # (cam_idx, track_id, {bin: (x, y)})
    for ci, floor in enumerate(cam_floor):
        for tid, obs in floor.items():
            d = {}
            for (t, x, y) in obs:
                d[round(t * fps)] = (x, y)
            if d:
                tracks.append((ci, tid, d))

    n = len(tracks)
    uf = _UnionFind(n)
    min_ov = max(1, int(cfg.MERGE_MIN_OVERLAP_SEC * fps))
    R = cfg.R_MERGE_M

    for i in range(n):
        ci, _, di = tracks[i]
        for j in range(i + 1, n):
            cj, _, dj = tracks[j]
            if ci == cj:
                continue  # track dari kamera yang sama = orang berbeda
            common = di.keys() & dj.keys()
            if len(common) < min_ov:
                continue
            dsum = 0.0
            for b in common:
                (x1, y1), (x2, y2) = di[b], dj[b]
                dsum += float(np.hypot(x1 - x2, y1 - y2))
            if dsum / len(common) < R:
                uf.union(i, j)

    groups = {}
    for i in range(n):
        groups.setdefault(uf.find(i), []).append(i)

    global_tracks = {}
    cam_to_global = {}
    gid = 0
    for _, members in groups.items():
        gid += 1
        binmap = {}
        for m in members:
            ci, tid, d = tracks[m]
            cam_to_global[(ci, tid)] = gid
            for b, (x, y) in d.items():
                binmap.setdefault(b, []).append((x, y))
        obs = []
        for b in sorted(binmap):
            arr = np.asarray(binmap[b])
            obs.append((b / fps, float(arr[:, 0].mean()), float(arr[:, 1].mean())))
        global_tracks[gid] = obs

    return global_tracks, cam_to_global