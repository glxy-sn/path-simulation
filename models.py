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


class CalibrationInput(BaseModel):
    """Kalibrasi authoritative dari app dalam koordinat normalized-image -> world."""

    homographyNormToWorld: list[list[float]]
    inlierMask: list[bool] = Field(default_factory=list)
    medianErrorM: Optional[float] = None
    p95ErrorM: Optional[float] = None
    inliers: Optional[int] = None
    points: Optional[int] = None


class CameraInput(BaseModel):
    cameraId: Optional[str] = None
    label: str
    videoPath: str
    calibrationFingerprint: Optional[str] = None
    frameWidth: Optional[int] = None
    frameHeight: Optional[int] = None
    imagePoints: list[Point] = Field(..., min_length=4, max_length=8)
    planePoints: list[Point] = Field(..., min_length=4, max_length=8)
    startSec: float = 0.0                 # mulai proses dari detik ke- (trim)
    durationSec: Optional[float] = None   # berapa lama diproses; None = pakai default engine
    timeOffsetSec: float = 0.0            # source time = global time + offset kamera
    calibration: Optional[CalibrationInput] = None


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
    overlayVideos: list[OverlayVideo] = Field(default_factory=list)
    fusionDiagnostics: Optional[str] = None


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


class IdentityQuality(BaseModel):
    globalIds: int = 0
    localStitches: int = 0
    overlapMerges: int = 0
    handoverMerges: int = 0
    unmatchedTracklets: int = 0
    filteredTracklets: int = 0
    highConfidence: int = 0
    mediumConfidence: int = 0
    lowConfidence: int = 0
    singleCamera: int = 0
    calibrationWarnings: list[str] = Field(default_factory=list)


class JobResult(BaseModel):
    jobId: str
    venue: VenueInput
    summary: Summary
    zones: list[Zone]
    stopPoints: list[StopPointOut]
    occupancy: list[OccupancyBin]
    blobs: list[HeatBlobOut] = Field(default_factory=list)
    paths: list[PathTraceOut] = Field(default_factory=list)
    artifacts: Artifacts
    trajectories: Optional[str] = None
    identityQuality: Optional[IdentityQuality] = None


class ProgressResponse(BaseModel):
    jobId: str
    status: str                     # queued | running | done | error
    stage: str                      # detection | tracking | fusion | analytics | done
    fraction: float                 # 0.0–1.0 (progress keseluruhan)
    error: Optional[str] = None


# ---------- Calibration preview ----------

class CalibrationPreviewRequest(BaseModel):
    venue: VenueInput
    cameras: list[CameraInput] = Field(..., min_length=1, max_length=2)
    globalTimeSec: float


class CalibrationReprojectRequest(BaseModel):
    token: str
    venue: VenueInput
    cameras: list[CameraInput] = Field(..., min_length=1, max_length=2)


class PreviewMarker(BaseModel):
    cameraIndex: int
    localId: int
    identityLabel: str
    globalId: Optional[int] = None
    bboxNorm: list[float]
    confidence: float
    worldX: float
    worldY: float
    identityScore: Optional[float] = None
    identityLevel: str


class PreviewCameraOut(BaseModel):
    cameraIndex: int
    cameraId: str
    label: str
    videoPath: str
    calibrationFingerprint: str
    sourceTimeSec: float
    frameWidth: int
    frameHeight: int
    frameJpegBase64: str
    markers: list[PreviewMarker] = Field(default_factory=list)


class PreviewMatchOut(BaseModel):
    cameraALocalId: int
    cameraBLocalId: int
    similarity: Optional[float] = None
    distanceM: float
    uncertaintyGateM: float
    score: Optional[float] = None
    decision: str
    reason: str


class CalibrationPreviewResponse(BaseModel):
    token: str
    globalTimeSec: float
    cameras: list[PreviewCameraOut]
    matches: list[PreviewMatchOut] = Field(default_factory=list)
    calibrationWarnings: list[str] = Field(default_factory=list)
    inferenceWarnings: list[str] = Field(default_factory=list)
