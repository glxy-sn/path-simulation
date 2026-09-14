"""Representative walking journeys, frequency first with supported coverage diversity."""
import numpy as np

PATH_DETAIL_MAX_VARIATIONS = 10
PATH_DETAIL_FREQUENCY_FRACTION = 0.70
PATH_DETAIL_MIN_SUPPORT = 2
PATH_DETAIL_MIN_SPAN_M = 3
PATH_DETAIL_MIN_LENGTH_M = 4.0
PATH_STOP_RADIUS_M = 0.35
PATH_STOP_SECONDS = 3.0
PATH_MAX_GAP_SECONDS = 2.0
PATH_MAX_SPEED_MPS = 3.0
PATH_CLUSTER_DISTANCE_M = 0.8
PATH_ENDPOINT_DISTANCE_M = 1.2


def walking_journeys(tracks):
    journeys = []
    def append(gid, rows):
        if len(rows) < 2:
            return
        points = np.asarray(rows)[:, 1:]
        length = np.linalg.norm(np.diff(points, axis=0), axis=1).sum()
        if (np.linalg.norm(np.ptp(points, axis=0)) >= PATH_DETAIL_MIN_SPAN_M
                and length >= PATH_DETAIL_MIN_LENGTH_M):
            journeys.append(dict(gid=gid, observations=list(rows)))
    for gid, observations in sorted(tracks.items()):
        runs, run = [], []
        for row in sorted(observations):
            if not np.isfinite(row).all():
                if run: runs.append(run)
                run = []
                continue
            if run:
                dt = row[0]-run[-1][0]
                distance = np.linalg.norm(np.asarray(row[1:])-run[-1][1:])
                if dt <= 0 or dt > PATH_MAX_GAP_SECONDS or distance/max(dt, 1e-9) > PATH_MAX_SPEED_MPS:
                    runs.append(run)
                    run = []
            run.append(row)
        if run: runs.append(run)
        for run in runs:
            start, i = 0, 0
            while i < len(run):
                j = i+1
                while j < len(run) and np.linalg.norm(np.asarray(run[j][1:])-run[i][1:]) <= PATH_STOP_RADIUS_M:
                    j += 1
                if run[j-1][0]-run[i][0] >= PATH_STOP_SECONDS:
                    append(gid, run[start:i+1])
                    start = j-1
                    i = j
                else:
                    i += 1
            append(gid, run[start:])
    return journeys


def _feature(rows):
    points = np.asarray(rows)[:, 1:]
    distances = np.r_[0, np.cumsum(np.linalg.norm(np.diff(points, axis=0), axis=1))]
    keep = np.r_[True, np.diff(distances)>0]
    points, distances = points[keep], distances[keep]
    samples = np.linspace(0, distances[-1], 32)
    return np.stack([np.interp(samples, distances, points[:, c]) for c in range(2)], axis=1)


def detail_path_groups(tracks, venue):
    journeys = walking_journeys(tracks)
    groups = []
    for journey in journeys:
        feature = _feature(journey['observations'])
        journey['feature'] = feature
        journey['cells'] = set(map(tuple, np.floor(feature/0.5).astype(int)))
        candidates = []
        for group in groups:
            reference = group[0]['feature']
            endpoints = np.linalg.norm(feature[[0,-1]]-reference[[0,-1]], axis=1)
            distance = np.linalg.norm(feature-reference, axis=1).mean()
            if endpoints.max() <= PATH_ENDPOINT_DISTANCE_M and distance <= PATH_CLUSTER_DISTANCE_M:
                candidates.append((distance, len(candidates), group))
        if candidates:
            min(candidates, key=lambda item: item[0])[2].append(journey)
        else:
            groups.append([journey])
    ranked = []
    for members in groups:
        if len(members) < PATH_DETAIL_MIN_SUPPORT:
            continue
        features = np.stack([j['feature'] for j in members])
        # Exact medoid in bounded chunks. The representative is an observed journey.
        costs = np.zeros(len(members))
        for i in range(len(members)):
            costs[i] = np.linalg.norm(features-features[i], axis=2).mean(axis=1).sum()
        representative = members[int(np.argmin(costs))]
        ranked.append(dict(observations=representative['observations'], count=len(members),
                           uniqueIDs=len({j['gid'] for j in members}),
                           share=len(members)/max(1,len(journeys)),
                           cells=set.union(*(j['cells'] for j in members))))
    ranked.sort(key=lambda g: (-g['count'], -g['uniqueIDs']))
    base = int(round(PATH_DETAIL_MAX_VARIATIONS*PATH_DETAIL_FREQUENCY_FRACTION))
    selected, remaining = ranked[:base], ranked[base:]
    covered = set.union(*(g['cells'] for g in selected)) if selected else set()
    while remaining and len(selected) < PATH_DETAIL_MAX_VARIATIONS:
        best = max(range(len(remaining)), key=lambda i: (len(remaining[i]['cells']-covered), remaining[i]['count']))
        group = remaining.pop(best)
        selected.append(group)
        covered.update(group['cells'])
    return selected


def select_detail_paths(tracks, venue):
    return {i+1: group['observations'] for i,group in enumerate(detail_path_groups(tracks, venue))}


def synchronize_detail_paths(tracks, duration=10.0, frames=300):
    """Animate each route by distance, preserving bends but discarding real timing."""
    output = {}
    for gid, observations in tracks.items():
        points = np.asarray([(x, y) for _, x, y in sorted(observations)], dtype=float)
        if len(points) < 2:
            continue
        distances = np.r_[0.0, np.cumsum(np.linalg.norm(np.diff(points, axis=0), axis=1))]
        keep = np.r_[True, np.diff(distances) > 0]
        points, distances = points[keep], distances[keep]
        if distances[-1] <= 0:
            continue
        times = distances / distances[-1] * duration
        # Keep original vertices so a frame cannot cut a corner in the route.
        sample_times = np.unique(np.r_[times, np.linspace(0.0, duration, frames)])
        xs = np.interp(sample_times, times, points[:, 0])
        ys = np.interp(sample_times, times, points[:, 1])
        output[gid] = list(zip(sample_times.tolist(), xs.tolist(), ys.tolist()))
    return output
