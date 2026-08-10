"""
Skema request/response. Cocok dengan yang dikirim app Swift:
- imagePoints / planePoints = titik ternormalisasi 0–1 (persis NormPoint di CalibrationView).
- videoPath = path absolut file video (dari file yang di-import).
Artifact besar (video, png, parquet) dikirim sebagai URI file://, bukan inline.
"""
from typing import Optional
from pydantic import BaseModel, Field


# ---------- Request ----------

class Point(BaseModel):
    x: float
    y: float


class VenueInput(BaseModel):
    widthM: float
    heightM: float
    name: str = ""
    type: str = ""
    floorPlanPath: str | None = None      # path gambar denah (opsional) untuk background


class CameraInput(BaseModel):
    label: str
    videoPath: str
    imagePoints: list[Point] = Field(..., min_length=4, max_length=8)
    planePoints: list[Point] = Field(..., min_length=4, max_length=8)
    startSec: float = 0.0                 # mulai proses dari detik ke- (trim)
    durationSec: Optional[float] = None   # berapa lama diproses; None = pakai default engine


class JobOptions(BaseModel):
    renderVideos: bool = True


class JobRequest(BaseModel):
    venue: VenueInput
    mode: str = "lengkap"           # "lengkap" | "cepat"
    cameras: list[CameraInput] = Field(..., min_length=1)
    options: JobOptions = JobOptions()


# ---------- Response ----------

class Summary(BaseModel):
    totalVisitors: int
    avgDwellSeconds: int
    peakOccupancy: int
    captureRate: float


class Rect(BaseModel):
    x: float
    y: float
    w: float
    h: float


class Zone(BaseModel):
    code: str
    visits: int
    share: float
    rect: Rect


class StopPointOut(BaseModel):
    label: str
    x: float
    y: float
    dwellSeconds: int


class OccupancyBin(BaseModel):
    minute: int
    count: int


class OverlayVideo(BaseModel):
    cam: str
    uri: str


class Artifacts(BaseModel):
    heatmapImage: Optional[str] = None
    pathVideo: Optional[str] = None
    combinedVideo: Optional[str] = None
    overlayVideos: list[OverlayVideo] = []


class HeatBlobOut(BaseModel):
    x: float
    y: float
    intensity: float
    radius: float


class PathPoint(BaseModel):
    x: float
    y: float
    t: float = 0.0


class PathTraceOut(BaseModel):
    points: list[PathPoint]
    hue: float


class JobResult(BaseModel):
    jobId: str
    venue: VenueInput
    summary: Summary
    zones: list[Zone]
    stopPoints: list[StopPointOut]
    occupancy: list[OccupancyBin]
    blobs: list[HeatBlobOut] = []
    paths: list[PathTraceOut] = []
    artifacts: Artifacts
    trajectories: Optional[str] = None


class ProgressResponse(BaseModel):
    jobId: str
    status: str                     # queued | running | done | error
    stage: str                      # detection | tracking | fusion | analytics | done
    fraction: float                 # 0.0–1.0 (progress keseluruhan)
    error: Optional[str] = None