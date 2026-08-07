"""
Tahap ANALITIK: dari trajektori global (t, gid, x_m, y_m) hitung metrik + heatmap +
zona + stop points + okupansi. Semua koordinat lantai dalam meter; output zona/stop
dinormalisasi 0–1 relatif dimensi venue supaya gampang digambar di UI.
"""
import numpy as np
from sklearn.cluster import DBSCAN

from models import Summary, Zone, Rect, StopPointOut, OccupancyBin


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
        binsec = cfg.OCC_BIN_SEC
        nb = int((tmax - tmin) // binsec) + 1
        counts = np.zeros(nb, dtype=int)
        for obs in global_tracks.values():
            present = {int((o[0] - tmin) // binsec) for o in obs}
            for b in present:
                if 0 <= b < nb:
                    counts[b] += 1
        peak = int(counts.max()) if nb else 0
        occ = [OccupancyBin(minute=int(round(b * binsec / 60)), count=int(counts[b]))
               for b in range(nb)]

    # ---- heatmap grid (untuk render) ----
    gw, gh = cfg.HEAT_GRID
    heat = np.zeros((gh, gw), dtype=float)
    for obs in global_tracks.values():
        for (_, x, y) in obs:
            cx = int(np.clip(x / W * gw, 0, gw - 1))
            cy = int(np.clip(y / Hm * gh, 0, gh - 1))
            heat[cy, cx] += 1

    # ---- zona (grid) ----
    zc, zr = cfg.ZONE_GRID
    cell_ids = [[set() for _ in range(zc)] for _ in range(zr)]
    for gid, obs in global_tracks.items():
        cells = set()
        for (_, x, y) in obs:
            cxi = int(np.clip(x / W * zc, 0, zc - 1))
            cyi = int(np.clip(y / Hm * zr, 0, zr - 1))
            cells.add((cyi, cxi))
        for (cyi, cxi) in cells:
            cell_ids[cyi][cxi].add(gid)

    ranked = sorted(
        ((len(cell_ids[r][c]), r, c) for r in range(zr) for c in range(zc) if cell_ids[r][c]),
        reverse=True,
    )
    maxv = ranked[0][0] if ranked else 1
    zones = []
    for i, (v, r, c) in enumerate(ranked[:cfg.ZONE_MAX]):
        zones.append(Zone(
            code=chr(ord('A') + i),
            visits=v,
            share=v / maxv,
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
            stops.append((pts[m, 0].mean(), pts[m, 1].mean(), int(durs[m].sum())))
        stops.sort(key=lambda s: s[2], reverse=True)

    stop_out = [
        StopPointOut(label=f"Stop {i + 1}", x=cx / W, y=cy / Hm, dwellSeconds=dur)
        for i, (cx, cy, dur) in enumerate(stops[:cfg.STOP_MAX])
    ]

    # ---- capture rate ----
    # CATATAN: capture rate butuh definisi domain (mis. garis pintu masuk vs. masuk toko).
    # Sementara dipakai proxy: fraksi pengunjung yang masuk zona tersibuk.
    # Ganti dengan definisi zona-pintu yang benar saat sudah ada zona buatan user.
    capture = float(min(zones[0].visits / total, 1.0)) if (total and zones) else 0.0

    summary = Summary(
        totalVisitors=total,
        avgDwellSeconds=avg_dwell,
        peakOccupancy=peak,
        captureRate=capture,
    )
    return {"summary": summary, "zones": zones, "stopPoints": stop_out, "occupancy": occ}, heat