"""Independent, render-only person segmentation. Never consumes tracking identities."""
from pathlib import Path
import os

import cv2
import numpy as np
import torch
from PIL import Image
from torchvision.models.segmentation import (
    DeepLabV3_MobileNet_V3_Large_Weights,
    deeplabv3_mobilenet_v3_large,
)

MODEL_FILENAME = "deeplabv3_mobilenet_v3_large-fc3c493d.pth"


def paint_person_mask(frame, mask):
    """Opaque fill with a small safety margin around the predicted silhouette."""
    mask = cv2.resize(mask.astype(np.uint8), (frame.shape[1], frame.shape[0]),
                      interpolation=cv2.INTER_NEAREST)
    radius = max(2, round(min(frame.shape[:2]) * 0.005))
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (radius * 2 + 1, radius * 2 + 1))
    mask = cv2.dilate(mask, kernel).astype(bool)
    result = frame.copy()
    result[mask] = (180, 130, 80)
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
        self.person_class = weights.meta["categories"].index("person")
        self.transform = weights.transforms()
        self.device = torch.device(device)
        self.model = deeplabv3_mobilenet_v3_large(
            weights=None, weights_backbone=None, num_classes=21, aux_loss=True,
        )
        self.model.load_state_dict(torch.load(checkpoint, map_location="cpu", weights_only=True))
        self.model.eval().to(self.device)

    @torch.inference_mode()
    def redact(self, frame):
        rgb = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        batch = self.transform(rgb).unsqueeze(0).to(self.device)
        probabilities = self.model(batch)["out"].softmax(dim=1)[0]
        # Include uncertain person pixels to cover more of the body's boundary.
        mask = ((probabilities.argmax(0) == self.person_class)
                | (probabilities[self.person_class] >= 0.20))
        return paint_person_mask(frame, mask.cpu().numpy())
