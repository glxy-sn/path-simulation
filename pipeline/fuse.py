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


def _norm(v):
    if v is None:
        return None
    v = np.asarray(v, dtype=np.float32).reshape(-1)
    nrm = float(np.linalg.norm(v))
    return v / nrm if nrm > 1e-6 else None


def fuse_tracks(cam_floor, cfg, cam_feats=None):
    """
    cam_floor: list per kamera berisi dict track_id -> list[(t, x_m, y_m)]
    cam_feats: list per kamera berisi dict track_id -> embedding penampilan (opsional)
    Return:
      global_tracks: dict gid(int) -> list[(t, x_m, y_m)]
      cam_to_global: dict (cam_idx, track_id) -> gid
    Gabung dua track antar-kamera bila: penampilan mirip (cosine>=APP) DAN geometri
    masuk radius longgar; ATAU (fallback) geometri masuk radius ketat.
    """
    fps = cfg.PROC_FPS
    tracks = []  # (cam_idx, track_id, {bin:(x,y)}, feat|None)
    for ci, floor in enumerate(cam_floor):
        feats = (cam_feats[ci] if (cam_feats and ci < len(cam_feats)) else {}) or {}
        for tid, obs in floor.items():
            d = {}
            for (t, x, y) in obs:
                d[round(t * fps)] = (x, y)
            if d:
                tracks.append((ci, tid, d, _norm(feats.get(tid))))

    n = len(tracks)
    uf = _UnionFind(n)
    min_ov = max(1, int(cfg.MERGE_MIN_OVERLAP_SEC * fps))
    R = cfg.R_MERGE_M
    R_LOOSE = getattr(cfg, "R_MERGE_APP_M", 3.5)
    APP = getattr(cfg, "APP_THRESH", 0.5)
    use_app = getattr(cfg, "WITH_APP_FUSION", True)
    n_feat = sum(1 for t in tracks if t[3] is not None)

    # Kumpulkan kandidat pasangan lintas-kamera + skor, lalu match SATU-LAWAN-SATU
    # (satu grup global = maksimal 1 track per kamera). Cegah cascade over-merge.
    edges = []
    for i in range(n):
        ci, _, di, fi = tracks[i]
        for j in range(i + 1, n):
            cj, _, dj, fj = tracks[j]
            if ci == cj:
                continue  # track dari kamera yang sama = orang berbeda
            common = di.keys() & dj.keys()
            if len(common) < min_ov:
                continue
            dmean = sum(float(np.hypot(di[b][0] - dj[b][0], di[b][1] - dj[b][1]))
                        for b in common) / len(common)

            score = None
            if use_app and fi is not None and fj is not None:
                sim = float(np.dot(fi, fj))           # cosine (ternormalisasi)
                if sim >= APP and dmean < R_LOOSE:
                    score = 1.0 + sim                 # appearance diprioritaskan
            if score is None and dmean < R:
                score = 1.0 - dmean / max(R, 1e-6)    # fallback geometri (skor lebih rendah)
            if score is not None:
                edges.append((score, i, j))

    edges.sort(key=lambda e: e[0], reverse=True)      # pasangan terbaik dulu
    root_cams = [{tracks[i][0]} for i in range(n)]    # kamera yang ada di tiap grup
    for score, i, j in edges:
        ri, rj = uf.find(i), uf.find(j)
        if ri == rj:
            continue
        if root_cams[ri] & root_cams[rj]:
            continue                                  # grup sudah punya track dari kamera itu -> tolak
        uf.union(i, j)
        nr = uf.find(i)
        root_cams[nr] = root_cams[ri] | root_cams[rj]

    groups = {}
    for i in range(n):
        groups.setdefault(uf.find(i), []).append(i)

    multicam = sum(1 for members in groups.values()
                   if len({tracks[m][0] for m in members}) > 1)
    print(f"[engine] fuse: {n} track-kamera -> {len(groups)} global "
          f"({multicam} gabungan multi-kamera | R={R}m, app<{R_LOOSE}m sim>={APP}, "
          f"embedding={n_feat}/{n})", flush=True)

    global_tracks = {}
    cam_to_global = {}
    gid = 0
    for _, members in groups.items():
        gid += 1
        binmap = {}
        for m in members:
            ci, tid, d, _f = tracks[m]
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