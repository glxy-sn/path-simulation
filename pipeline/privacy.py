"""Independent, render-only person segmentation. Never consumes tracking identities."""
from pathlib import Path
import os
import time

import cv2
import numpy as np
import torch
from PIL import Image
from torchvision.models.segmentation import (
    DeepLabV3_MobileNet_V3_Large_Weights,
    deeplabv3_mobilenet_v3_large,
)

# Smaller values produce smaller mosaic blocks. Ratio is relative to the shorter frame side.
PIXEL_BLOCK_RATIO = 0.05
PIXEL_BLOCK_MIN_PX = 10

MODEL_FILENAME = "deeplabv3_mobilenet_v3_large-fc3c493d.pth"


def paint_person_mask(frame, mask):
    """Coarse mosaic within the silhouette, with an expanded boundary."""
    mask = cv2.resize(mask.astype(np.uint8), (frame.shape[1], frame.shape[0]),
                      interpolation=cv2.INTER_NEAREST)
    radius = max(2, round(min(frame.shape[:2]) * 0.005))
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (radius * 2 + 1, radius * 2 + 1))
    mask = cv2.dilate(mask, kernel).astype(bool)
    result = frame.copy()
    # Mosaic strength is configured by the constants above.
    block = max(PIXEL_BLOCK_MIN_PX, round(min(frame.shape[:2]) * PIXEL_BLOCK_RATIO))
    small = cv2.resize(frame, (max(1, frame.shape[1] // block),
                               max(1, frame.shape[0] // block)), interpolation=cv2.INTER_AREA)
    mosaic = cv2.resize(small, (frame.shape[1], frame.shape[0]), interpolation=cv2.INTER_NEAREST)
    result[mask] = mosaic[mask]
    return result


class PersonPrivacy:
    def __init__(self, device="cpu"):
        root = os.getenv("USEE_MODELS_ROOT") or os.getenv("FOODCOURT_MODELS_ROOT")
        local_root = Path(__file__).resolve().parents[1] / "models"
        roots = [Path(root).expanduser(), local_root] if root else [local_root]
        checkpoint = next((folder / MODEL_FILENAME for folder in roots
                           if (folder / MODEL_FILENAME).is_file()), roots[0] / MODEL_FILENAME)
        if not checkpoint.is_file():
            raise RuntimeError(f"Model segmentasi privasi belum tersedia: {checkpoint}")
        weights = DeepLabV3_MobileNet_V3_Large_Weights.DEFAULT
        self.inference_seconds = 0.0
        self.person_class = weights.meta["categories"].index("person")
        self.transform = weights.transforms()
        self.device = torch.device(device)
        self.model = deeplabv3_mobilenet_v3_large(
            weights=None, weights_backbone=None, num_classes=21, aux_loss=True,
        )
        self.model.load_state_dict(torch.load(checkpoint, map_location="cpu", weights_only=True))
        self.model.eval().to(self.device)

    def redact(self, frame):
        return self.redact_batch([frame])[0]

    @torch.inference_mode()
    def redact_batch(self, frames):
        """Bounded batches, grouped by tensor shape. Every output has a fresh mask."""
        started = time.perf_counter()
        limit = max(1, int(os.getenv("PRISM_PRIVACY_BATCH", "2")))
        output = [None] * len(frames)
        for start in range(0, len(frames), limit):
            groups = {}
            for index in range(start, min(start + limit, len(frames))):
                rgb = Image.fromarray(cv2.cvtColor(frames[index], cv2.COLOR_BGR2RGB))
                tensor = self.transform(rgb)
                groups.setdefault(tuple(tensor.shape), []).append((index, tensor))
            for items in groups.values():
                batch = torch.stack([t for _, t in items]).to(self.device)
                probabilities = self.model(batch)["out"].softmax(dim=1)
                masks = ((probabilities.argmax(1) == self.person_class)
                         | (probabilities[:, self.person_class] >= 0.20)).cpu().numpy()
                for (index, _), mask in zip(items, masks):
                    output[index] = paint_person_mask(frames[index], mask)
        self.inference_seconds += time.perf_counter() - started
        return output
