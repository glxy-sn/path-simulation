# """
# Tahap ANALITIK: dari trajektori global (t, gid, x_m, y_m) hitung metrik + heatmap +
# zona + stop points + okupansi. Semua koordinat lantai dalam meter; output zona/stop
# dinormalisasi 0–1 relatif dimensi venue supaya gampang digambar di UI.
# """
# import numpy as np
# from sklearn.cluster import DBSCAN

# from models import Summary, Zone, Rect, StopPointOut, OccupancyBin, HeatBlobOut, PathPoint, PathTraceOut


# def compute_analytics(global_tracks, venue, cfg):
#     W, Hm = float(venue.widthM), float(venue.heightM)
#     total = len(global_tracks)

#     # ---- dwell (presence) + rentang waktu ----
#     dwell, tmin, tmax = [], 1e18, -1e18
#     for obs in global_tracks.values():
#         ts = [o[0] for o in obs]
#         if not ts:
#             continue
#         dwell.append(max(ts) - min(ts))
#         tmin, tmax = min(tmin, min(ts)), max(tmax, max(ts))
#     avg_dwell = int(np.mean(dwell)) if dwell else 0

#     # ---- okupansi per bin + puncak ----
#     occ, peak = [], 0
#     if total and tmax > tmin:
#         binsec = cfg.OCC_BIN_SEC
#         nb = int((tmax - tmin) // binsec) + 1
#         counts = np.zeros(nb, dtype=int)
#         for obs in global_tracks.values():
#             present = {int((o[0] - tmin) // binsec) for o in obs}
#             for b in present:
#                 if 0 <= b < nb:
#                     counts[b] += 1
#         peak = int(counts.max()) if nb else 0
#         occ = [OccupancyBin(minute=int(round(b * binsec / 60)), count=int(counts[b]))
#                for b in range(nb)]

#     # ---- heatmap grid (untuk render) ----
#     gw, gh = cfg.HEAT_GRID
#     heat = np.zeros((gh, gw), dtype=float)
#     for obs in global_tracks.values():
#         for (_, x, y) in obs:
#             cx = int(np.clip(x / W * gw, 0, gw - 1))
#             cy = int(np.clip(y / Hm * gh, 0, gh - 1))
#             heat[cy, cx] += 1

#     # ---- zona (grid) — "visits" = jumlah PENGAMATAN titik-kaki (bebas identitas) ----
#     zc, zr = cfg.ZONE_GRID
#     cell_count = np.zeros((zr, zc), dtype=float)
#     for gid, obs in global_tracks.items():
#         for (_, x, y) in obs:
#             cxi = int(np.clip(x / W * zc, 0, zc - 1))
#             cyi = int(np.clip(y / Hm * zr, 0, zr - 1))
#             cell_count[cyi, cxi] += 1

#     ranked = sorted(
#         ((cell_count[r][c], r, c) for r in range(zr) for c in range(zc) if cell_count[r][c] > 0),
#         reverse=True,
#     )
#     maxv = ranked[0][0] if ranked else 1
#     zones = []
#     for i, (v, r, c) in enumerate(ranked[:cfg.ZONE_MAX]):
#         zones.append(Zone(
#             code=chr(ord('A') + i),
#             visits=int(v),
#             share=float(v / maxv),
#             rect=Rect(x=c / zc, y=r / zr, w=1.0 / zc, h=1.0 / zr),
#         ))

#     # ---- stop points (segmen kecepatan rendah, lalu di-cluster) ----
#     stops_raw = []  # (x, y, durasi)
#     for obs in global_tracks.values():
#         o = sorted(obs)
#         run_pts, run_t0, last = [], None, None
#         for (t, x, y) in o:
#             if last is not None:
#                 dt = t - last[0]
#                 spd = (np.hypot(x - last[1], y - last[2]) / dt) if dt > 0 else 0.0
#                 if spd < cfg.STOP_SPEED_MPS:
#                     if run_t0 is None:
#                         run_t0, run_pts = last[0], [(last[1], last[2])]
#                     run_pts.append((x, y))
#                 else:
#                     if run_t0 is not None and (last[0] - run_t0) >= cfg.STOP_MIN_SEC:
#                         arr = np.asarray(run_pts)
#                         stops_raw.append((arr[:, 0].mean(), arr[:, 1].mean(), last[0] - run_t0))
#                     run_t0, run_pts = None, []
#             last = (t, x, y)
#         if run_t0 is not None and last is not None and (last[0] - run_t0) >= cfg.STOP_MIN_SEC:
#             arr = np.asarray(run_pts)
#             stops_raw.append((arr[:, 0].mean(), arr[:, 1].mean(), last[0] - run_t0))

#     stops = []
#     if stops_raw:
#         pts = np.array([[s[0], s[1]] for s in stops_raw])
#         durs = np.array([s[2] for s in stops_raw])
#         labels = DBSCAN(eps=cfg.STOP_MERGE_M, min_samples=1).fit(pts).labels_
#         for lab in set(labels):
#             m = labels == lab
#             stops.append((pts[m, 0].mean(), pts[m, 1].mean(), int(durs[m].sum())))
#         stops.sort(key=lambda s: s[2], reverse=True)

#     stop_out = [
#         StopPointOut(label=f"Stop {i + 1}", x=cx / W, y=cy / Hm, dwellSeconds=dur)
#         for i, (cx, cy, dur) in enumerate(stops[:cfg.STOP_MAX])
#     ]

#     # ---- capture rate ----
#     # Tanpa ground-truth, recall sebenarnya tak bisa dihitung. Dipakai PROXY:
#     # kontinuitas deteksi — rata-rata seberapa penuh sebuah track teramati
#     # sepanjang hidupnya (points aktual / frame yang seharusnya). Tinggi = deteksi
#     # jarang bolong. Ini indikator kualitas, bukan recall pasti.
#     proc_fps = getattr(cfg, "PROC_FPS", 5.0)
#     conts = []
#     for obs in global_tracks.values():
#         ts = [o[0] for o in obs]
#         span = max(ts) - min(ts) if len(ts) > 1 else 0.0
#         expected = span * proc_fps + 1.0
#         conts.append(min(1.0, len(obs) / expected))
#     capture = float(np.mean(conts)) if conts else 0.0

#     # ---- blobs: puncak kepadatan lantai (heatmap data-driven, bebas identitas) ----
#     gw, gh = cfg.HEAT_GRID
#     blobs = []
#     work = heat.copy()
#     hmax = float(heat.max()) if heat.max() > 0 else 1.0
#     for _ in range(getattr(cfg, "BLOB_MAX", 28)):
#         if work.max() <= 0:
#             break
#         fy, fx = np.unravel_index(int(work.argmax()), work.shape)
#         blobs.append(HeatBlobOut(
#             x=round(float((fx + 0.5) / gw), 4),
#             y=round(float((fy + 0.5) / gh), 4),
#             intensity=round(float(work[fy, fx] / hmax), 3),
#             radius=float(getattr(cfg, "BLOB_RADIUS", 0.06)),
#         ))
#         y0, y1 = max(0, fy - 1), min(gh, fy + 2)
#         x0, x1 = max(0, fx - 1), min(gw, fx + 2)
#         work[y0:y1, x0:x1] = 0

#     # ---- paths: lintasan lantai ternormalisasi (path simulation data-driven) ----
#     paths = []
#     by_len = sorted(global_tracks.items(), key=lambda kv: -len(kv[1]))
#     for i, (gid, obs) in enumerate(by_len[:getattr(cfg, "PATH_MAX", 12)]):
#         pts = [PathPoint(x=round(float(np.clip(x / W, 0, 1)), 4),
#                          y=round(float(np.clip(y / Hm, 0, 1)), 4),
#                          t=round(float(tt), 2)) for (tt, x, y) in obs]
#         if len(pts) >= 2:
#             paths.append(PathTraceOut(points=pts, hue=round((i * 0.618) % 1.0, 3)))

#     # ---- observations: semua titik-kaki lantai ternormalisasi (untuk zona custom di app) ----
#     obs_all = []
#     for obs in global_tracks.values():
#         for (_, x, y) in obs:
#             obs_all.append((round(float(np.clip(x / W, 0, 1)), 4),
#                             round(float(np.clip(y / Hm, 0, 1)), 4)))
#     # cap ~5000 titik biar payload ringan
#     cap = 5000
#     if len(obs_all) > cap:
#         step = (len(obs_all) + cap - 1) // cap
#         obs_all = obs_all[::step]
#     observations = [[a, b] for (a, b) in obs_all]

#     summary = Summary(
#         totalVisitors=total,
#         avgDwellSeconds=avg_dwell,
#         peakOccupancy=peak,
#         captureRate=capture,
#     )
#     return {"summary": summary, "zones": zones, "stopPoints": stop_out,
#             "occupancy": occ, "blobs": blobs, "paths": paths,
#             "observations": observations}, heat
"""
Tahap ANALITIK: dari trajektori global (t, gid, x_m, y_m) hitung metrik + heatmap +
zona + stop points + okupansi. Semua koordinat lantai dalam meter; output zona/stop
dinormalisasi 0–1 relatif dimensi venue supaya gampang digambar di UI.
"""
import numpy as np
from sklearn.cluster import DBSCAN

from models import Summary, Zone, Rect, StopPointOut, OccupancyBin, HeatBlobOut, PathPoint, PathTraceOut


def compute_analytics(global_tracks, venue, cfg):
    W, Hm = float(venue.widthM), float(venue.heightM)
    total = len(global_tracks)

    # ---- dwell (presence) + rentang waktu ----
    dwell, tmin, tmax = [], 1e18, -1e18
    for obs in global_tracks.values():
        ts = [o[0] for o in obs]
        if not ts:
            continue
        dwell.append(max(ts) - min(ts))
        tmin, tmax = min(tmin, min(ts)), max(tmax, max(ts))
    avg_dwell = int(np.mean(dwell)) if dwell else 0

    # ---- okupansi per bin + puncak ----
    occ, peak = [], 0
    if total and tmax > tmin:
        # Rekaman pendek (demo biasanya di bawah satu menit) hanya menghasilkan
        # satu bin kalau lebarnya tetap 60 detik, dan grafiknya jadi kosong.
        # Untuk itu lebar bin dipersempit agar tetap ada sekitar 12 titik.
        binsec = cfg.OCC_BIN_SEC
        span = tmax - tmin
        if span < binsec * 3:
            binsec = max(1.0, span / 12.0)
        nb = int((tmax - tmin) // binsec) + 1
        counts = np.zeros(nb, dtype=int)
        for obs in global_tracks.values():
            present = {int((o[0] - tmin) // binsec) for o in obs}
            for b in present:
                if 0 <= b < nb:
                    counts[b] += 1
        peak = int(counts.max()) if nb else 0
        occ = [OccupancyBin(minute=int(round(b * binsec / 60)),
                            second=int(round(b * binsec)),
                            count=int(counts[b]))
               for b in range(nb)]

    # ---- heatmap grid (untuk render) ----
    gw, gh = cfg.HEAT_GRID
    heat = np.zeros((gh, gw), dtype=float)
    for obs in global_tracks.values():
        for (_, x, y) in obs:
            cx = int(np.clip(x / W * gw, 0, gw - 1))
            cy = int(np.clip(y / Hm * gh, 0, gh - 1))
            heat[cy, cx] += 1

    # ---- zona (grid) — "visits" = jumlah PENGAMATAN titik-kaki (bebas identitas) ----
    zc, zr = cfg.ZONE_GRID
    cell_count = np.zeros((zr, zc), dtype=float)
    for gid, obs in global_tracks.items():
        for (_, x, y) in obs:
            cxi = int(np.clip(x / W * zc, 0, zc - 1))
            cyi = int(np.clip(y / Hm * zr, 0, zr - 1))
            cell_count[cyi, cxi] += 1

    ranked = sorted(
        ((cell_count[r][c], r, c) for r in range(zr) for c in range(zc) if cell_count[r][c] > 0),
        reverse=True,
    )
    maxv = ranked[0][0] if ranked else 1
    zones = []
    for i, (v, r, c) in enumerate(ranked[:cfg.ZONE_MAX]):
        zones.append(Zone(
            code=chr(ord('A') + i),
            visits=int(v),
            share=float(v / maxv),
            rect=Rect(x=c / zc, y=r / zr, w=1.0 / zc, h=1.0 / zr),
        ))

    # ---- stop points (segmen kecepatan rendah, lalu di-cluster) ----
    stops_raw = []  # (x, y, durasi)
    for obs in global_tracks.values():
        o = sorted(obs)
        run_pts, run_t0, last = [], None, None
        for (t, x, y) in o:
            if last is not None:
                dt = t - last[0]
                spd = (np.hypot(x - last[1], y - last[2]) / dt) if dt > 0 else 0.0
                if spd < cfg.STOP_SPEED_MPS:
                    if run_t0 is None:
                        run_t0, run_pts = last[0], [(last[1], last[2])]
                    run_pts.append((x, y))
                else:
                    if run_t0 is not None and (last[0] - run_t0) >= cfg.STOP_MIN_SEC:
                        arr = np.asarray(run_pts)
                        stops_raw.append((arr[:, 0].mean(), arr[:, 1].mean(), last[0] - run_t0))
                    run_t0, run_pts = None, []
            last = (t, x, y)
        if run_t0 is not None and last is not None and (last[0] - run_t0) >= cfg.STOP_MIN_SEC:
            arr = np.asarray(run_pts)
            stops_raw.append((arr[:, 0].mean(), arr[:, 1].mean(), last[0] - run_t0))

    stops = []
    if stops_raw:
        pts = np.array([[s[0], s[1]] for s in stops_raw])
        durs = np.array([s[2] for s in stops_raw])
        labels = DBSCAN(eps=cfg.STOP_MERGE_M, min_samples=1).fit(pts).labels_
        for lab in set(labels):
            m = labels == lab
            # rata-rata lama berhenti per orang di titik ini (bukan dijumlah -> tak melebihi durasi video)
            stops.append((pts[m, 0].mean(), pts[m, 1].mean(), int(durs[m].mean())))
        stops.sort(key=lambda s: s[2], reverse=True)

    stop_out = [
        StopPointOut(label=f"Stop {i + 1}", x=cx / W, y=cy / Hm, dwellSeconds=dur)
        for i, (cx, cy, dur) in enumerate(stops[:cfg.STOP_MAX])
    ]

    # ---- capture rate ----
    # Tanpa ground-truth, recall sebenarnya tak bisa dihitung. Dipakai PROXY:
    # kontinuitas deteksi — rata-rata seberapa penuh sebuah track teramati
    # sepanjang hidupnya (points aktual / frame yang seharusnya). Tinggi = deteksi
    # jarang bolong. Ini indikator kualitas, bukan recall pasti.
    proc_fps = getattr(cfg, "PROC_FPS", 5.0)
    conts = []
    for obs in global_tracks.values():
        ts = [o[0] for o in obs]
        span = max(ts) - min(ts) if len(ts) > 1 else 0.0
        expected = span * proc_fps + 1.0
        conts.append(min(1.0, len(obs) / expected))
    capture = float(np.mean(conts)) if conts else 0.0

    # ---- blobs: puncak kepadatan lantai (heatmap data-driven, bebas identitas) ----
    gw, gh = cfg.HEAT_GRID
    blobs = []
    work = heat.copy()
    hmax = float(heat.max()) if heat.max() > 0 else 1.0
    for _ in range(getattr(cfg, "BLOB_MAX", 28)):
        if work.max() <= 0:
            break
        fy, fx = np.unravel_index(int(work.argmax()), work.shape)
        blobs.append(HeatBlobOut(
            x=round(float((fx + 0.5) / gw), 4),
            y=round(float((fy + 0.5) / gh), 4),
            intensity=round(float(work[fy, fx] / hmax), 3),
            radius=float(getattr(cfg, "BLOB_RADIUS", 0.06)),
        ))
        y0, y1 = max(0, fy - 1), min(gh, fy + 2)
        x0, x1 = max(0, fx - 1), min(gw, fx + 2)
        work[y0:y1, x0:x1] = 0

    # ---- paths: lintasan lantai ternormalisasi (path simulation data-driven) ----
    paths = []
    by_len = sorted(global_tracks.items(), key=lambda kv: -len(kv[1]))
    for i, (gid, obs) in enumerate(by_len[:getattr(cfg, "PATH_MAX", 12)]):
        pts = [PathPoint(x=round(float(np.clip(x / W, 0, 1)), 4),
                         y=round(float(np.clip(y / Hm, 0, 1)), 4),
                         t=round(float(tt), 2)) for (tt, x, y) in obs]
        if len(pts) >= 2:
            paths.append(PathTraceOut(points=pts, hue=round((i * 0.618) % 1.0, 3)))

    # ---- observations: [track_id, x, y, t] ternormalisasi (untuk metrik zona custom) ----
    obs_all = []
    for gid, obs in global_tracks.items():
        for (t, x, y) in obs:
            obs_all.append((int(gid),
                            round(float(np.clip(x / W, 0, 1)), 4),
                            round(float(np.clip(y / Hm, 0, 1)), 4),
                            round(float(t), 2)))
    cap = 6000
    if len(obs_all) > cap:
        step = (len(obs_all) + cap - 1) // cap
        obs_all = obs_all[::step]
    observations = [[float(g), x, y, t] for (g, x, y, t) in obs_all]

    summary = Summary(
        totalVisitors=total,
        avgDwellSeconds=avg_dwell,
        peakOccupancy=peak,
        captureRate=capture,
    )
    return {"summary": summary, "zones": zones, "stopPoints": stop_out,
            "occupancy": occ, "blobs": blobs, "paths": paths,
            "observations": observations}, heat