
# import numpy as np


# class _UnionFind:
#     def __init__(self, n):
#         self.p = list(range(n))

#     def find(self, x):
#         while self.p[x] != x:
#             self.p[x] = self.p[self.p[x]]
#             x = self.p[x]
#         return x

#     def union(self, a, b):
#         self.p[self.find(a)] = self.find(b)


# def fuse_tracks(cam_floor, cfg):
#     """
#     cam_floor: list per kamera berisi dict track_id -> list[(t, x_m, y_m)]
#     Return:
#       global_tracks: dict gid(int) -> list[(t, x_m, y_m)]  (posisi dirata-rata di zona overlap)
#       cam_to_global: dict (cam_idx, track_id) -> gid   (untuk render overlay)
#     """
#     fps = cfg.PROC_FPS
#     tracks = []  # (cam_idx, track_id, {bin: (x, y)})
#     for ci, floor in enumerate(cam_floor):
#         for tid, obs in floor.items():
#             d = {}
#             for (t, x, y) in obs:
#                 d[round(t * fps)] = (x, y)
#             if d:
#                 tracks.append((ci, tid, d))

#     n = len(tracks)
#     uf = _UnionFind(n)
#     min_ov = max(1, int(cfg.MERGE_MIN_OVERLAP_SEC * fps))
#     R = cfg.R_MERGE_M

#     for i in range(n):
#         ci, _, di = tracks[i]
#         for j in range(i + 1, n):
#             cj, _, dj = tracks[j]
#             if ci == cj:
#                 continue  # track dari kamera yang sama = orang berbeda
#             common = di.keys() & dj.keys()
#             if len(common) < min_ov:
#                 continue
#             dsum = 0.0
#             for b in common:
#                 (x1, y1), (x2, y2) = di[b], dj[b]
#                 dsum += float(np.hypot(x1 - x2, y1 - y2))
#             if dsum / len(common) < R:
#                 uf.union(i, j)

#     groups = {}
#     for i in range(n):
#         groups.setdefault(uf.find(i), []).append(i)

#     global_tracks = {}
#     cam_to_global = {}
#     gid = 0
#     for _, members in groups.items():
#         gid += 1
#         binmap = {}
#         for m in members:
#             ci, tid, d = tracks[m]
#             cam_to_global[(ci, tid)] = gid
#             for b, (x, y) in d.items():
#                 binmap.setdefault(b, []).append((x, y))
#         obs = []
#         for b in sorted(binmap):
#             arr = np.asarray(binmap[b])
#             obs.append((b / fps, float(arr[:, 0].mean()), float(arr[:, 1].mean())))
#         global_tracks[gid] = obs

#     return global_tracks, cam_to_global

"""
Tahap FUSION multi-kamera — versi LEVEL-TRACK (untuk overlap kamera yang jarang).

Kenapa bukan DBSCAN(min_samples=2) per-frame seperti WILDTRACK?
Di WILDTRACK 7 kamera saling overlap penuh, jadi wajib butuh >=2 kamera konfirmasi.
Di venue asli, kamera biasanya minim overlap; kalau butuh 2 kamera, orang yang
cuma terlihat 1 kamera (mayoritas) akan hilang. Maka:
  - tiap track per-kamera diproyeksikan ke lantai;
  - dua track dari kamera BERBEDA di-merge kalau overlap waktu cukup DAN jarak
    rata-rata di periode overlap < R_MERGE (artinya orang yang sama di zona overlap);
  - track single-kamera tetap jadi ID global sendiri.
"""
import numpy as np
from collections import defaultdict


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


def stitch_tracks(tracks, cfg):
    """
    ID stitching: sambung track yang PECAH (satu orang ke-track putus-putus).
    Kriteria sederhana di bidang lantai: track B mulai sesaat setelah A berakhir
    (gap kecil) DAN posisi awal B dekat dengan posisi akhir A. Ini mengurangi
    over-counting akibat fragmentation (biang "77 pengunjung").

    Return: (tracks_tergabung, remap {gid_lama: gid_baru})
    """
    max_gap = getattr(cfg, "STITCH_MAX_GAP_SEC", 2.0)
    max_dist = getattr(cfg, "STITCH_MAX_DIST_M", 1.5)

    items = [(g, sorted(o)) for g, o in tracks.items() if o]
    items.sort(key=lambda kv: kv[1][0][0])          # urut waktu mulai

    parent = {g: g for g, _ in items}

    def find(g):
        r = g
        while parent[r] != r:
            r = parent[r]
        while parent[g] != r:
            parent[g], g = r, parent[g]
        return r

    open_tracks = []   # (end_t, end_x, end_y, gid) yang siap disambung
    for g, obs in items:
        t0, x0, y0 = obs[0]
        open_tracks = [e for e in open_tracks if t0 - e[0] <= max_gap]   # buang kadaluarsa
        best, best_cost, best_idx = None, 1e18, -1
        for idx, (te, xe, ye, pg) in enumerate(open_tracks):
            gap = t0 - te
            if gap < 0:
                continue
            d = float(np.hypot(x0 - xe, y0 - ye))
            if d > max_dist:
                continue
            cost = d + gap * 0.5
            if cost < best_cost:
                best_cost, best, best_idx = cost, pg, idx
        if best is not None:
            parent[find(g)] = find(best)
            open_tracks.pop(best_idx)               # sekali pakai (orang tak bercabang)
        te, xe, ye = obs[-1]
        open_tracks.append((te, xe, ye, g))

    out = defaultdict(list)
    for g, obs in tracks.items():
        out[find(g)].extend(obs)
    for g in out:
        out[g].sort()
    remap = {g: find(g) for g in tracks}
    return dict(out), remap