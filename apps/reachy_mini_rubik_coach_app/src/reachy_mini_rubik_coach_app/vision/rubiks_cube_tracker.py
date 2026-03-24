from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass
from typing import Dict, List, Tuple

import cv2
import numpy as np
from numpy.typing import NDArray


logger = logging.getLogger(__name__)


@dataclass
class StickerCandidate:
    """A candidate colored sticker that may belong to a Rubik's cube face."""

    color: str
    center: Tuple[float, float]
    bbox: Tuple[int, int, int, int]
    area: float
    side: float


class HeadTracker:
    """Track a Rubik's cube by clustering colored square-like regions."""

    def __init__(self, smoothing: float = 0.65) -> None:
        self.smoothing = smoothing
        self._lock = threading.Lock()
        self._tracking_enabled = True
        self._smoothed_center: NDArray[np.float32] | None = None
        self._last_status: Dict[str, object] = {
            "tracking_enabled": True,
            "detected": False,
            "confidence": 0.0,
            "color_count": 0,
            "sticker_count": 0,
            "center_norm": None,
            "bbox_px": None,
            "last_seen_age_s": None,
        }
        self._last_seen_ts: float | None = None

        self._color_ranges: Dict[str, List[Tuple[Tuple[int, int, int], Tuple[int, int, int]]]] = {
            "red": [((0, 90, 70), (12, 255, 255)), ((165, 90, 70), (179, 255, 255))],
            "orange": [((10, 110, 70), (24, 255, 255))],
            "yellow": [((20, 90, 90), (38, 255, 255))],
            "green": [((38, 55, 45), (90, 255, 255))],
            "blue": [((90, 70, 45), (135, 255, 255))],
            "white": [((0, 0, 140), (179, 70, 255))],
        }

    def set_tracking_enabled(self, enabled: bool) -> None:
        """Enable or disable tracking."""
        with self._lock:
            self._tracking_enabled = enabled
            self._last_status["tracking_enabled"] = enabled
        if not enabled:
            self._smoothed_center = None

    def get_status(self) -> Dict[str, object]:
        """Return the latest tracking status."""
        with self._lock:
            status = dict(self._last_status)
        if self._last_seen_ts is not None:
            status["last_seen_age_s"] = round(max(0.0, time.time() - self._last_seen_ts), 2)
        return status

    def get_head_position(self, img: NDArray[np.uint8]) -> Tuple[NDArray[np.float32] | None, float | None]:
        """Return cube center in normalized [-1, 1] coordinates for head-following."""
        if not self._tracking_enabled:
            return None, None

        detection = self._detect_cube(img)
        with self._lock:
            self._last_status.update(detection)
            self._last_status["tracking_enabled"] = self._tracking_enabled

        center_norm = detection.get("center_norm")
        if not detection["detected"] or not isinstance(center_norm, tuple):
            self._smoothed_center = None
            return None, None

        current_center = np.array(center_norm, dtype=np.float32)
        if self._smoothed_center is None:
            self._smoothed_center = current_center
        else:
            self._smoothed_center = (
                self.smoothing * self._smoothed_center + (1.0 - self.smoothing) * current_center
            ).astype(np.float32)

        return self._smoothed_center.copy(), 0.0

    def _detect_cube(self, img: NDArray[np.uint8]) -> Dict[str, object]:
        """Detect a cluster of colored stickers likely to be a Rubik's cube face."""
        h, w = img.shape[:2]
        img_area = float(h * w)
        min_area = max(90.0, img_area * 0.00012)
        max_area = img_area * 0.12

        hsv = cv2.cvtColor(cv2.GaussianBlur(img, (5, 5), 0), cv2.COLOR_BGR2HSV)
        kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))
        candidates: List[StickerCandidate] = []

        for color, ranges in self._color_ranges.items():
            mask = np.zeros((h, w), dtype=np.uint8)
            for lower, upper in ranges:
                mask |= cv2.inRange(hsv, np.array(lower, dtype=np.uint8), np.array(upper, dtype=np.uint8))

            mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
            mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
            contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

            for contour in contours:
                area = float(cv2.contourArea(contour))
                if area < min_area or area > max_area:
                    continue

                x, y, bw, bh = cv2.boundingRect(contour)
                box_area = float(max(1, bw * bh))
                aspect = bw / float(max(1, bh))
                fill_ratio = area / box_area
                if aspect < 0.45 or aspect > 1.75 or fill_ratio < 0.42:
                    continue

                side = float((bw + bh) / 2.0)
                candidates.append(
                    StickerCandidate(
                        color=color,
                        center=(x + bw / 2.0, y + bh / 2.0),
                        bbox=(x, y, x + bw, y + bh),
                        area=area,
                        side=side,
                    )
                )

        if not candidates:
            return self._empty_detection()

        best_cluster = self._select_best_cluster(candidates, w, h)
        if best_cluster is None:
            return self._empty_detection()

        cluster_candidates, confidence = best_cluster
        colors = sorted({candidate.color for candidate in cluster_candidates})
        x1 = min(candidate.bbox[0] for candidate in cluster_candidates)
        y1 = min(candidate.bbox[1] for candidate in cluster_candidates)
        x2 = max(candidate.bbox[2] for candidate in cluster_candidates)
        y2 = max(candidate.bbox[3] for candidate in cluster_candidates)

        center_x = (x1 + x2) / 2.0
        center_y = (y1 + y2) / 2.0
        center_norm = ((center_x / w) * 2.0 - 1.0, (center_y / h) * 2.0 - 1.0)
        bbox_area_fraction = (max(1.0, float(x2 - x1)) * max(1.0, float(y2 - y1))) / max(1.0, float(w * h))
        horizontal_position = self._axis_hint(center_norm[0], negative="left", positive="right")
        vertical_position = self._axis_hint(center_norm[1], negative="up", positive="down")
        centered = abs(center_norm[0]) < 0.18 and abs(center_norm[1]) < 0.18

        self._last_seen_ts = time.time()
        return {
            "detected": True,
            "confidence": round(confidence, 3),
            "color_count": len(colors),
            "colors": colors,
            "sticker_count": len(cluster_candidates),
            "center_norm": (round(center_norm[0], 4), round(center_norm[1], 4)),
            "bbox_px": (int(x1), int(y1), int(x2), int(y2)),
            "size_fraction": round(bbox_area_fraction, 4),
            "centered": centered,
            "horizontal_position": horizontal_position,
            "vertical_position": vertical_position,
            "last_seen_age_s": 0.0,
        }

    def _select_best_cluster(
        self,
        candidates: List[StickerCandidate],
        width: int,
        height: int,
    ) -> Tuple[List[StickerCandidate], float] | None:
        """Pick the best candidate cluster based on compactness and color richness."""
        remaining = list(range(len(candidates)))
        clusters: List[List[int]] = []

        while remaining:
            cluster = [remaining.pop(0)]
            changed = True
            while changed:
                changed = False
                for idx in remaining[:]:
                    if any(self._is_neighbor(candidates[idx], candidates[member]) for member in cluster):
                        remaining.remove(idx)
                        cluster.append(idx)
                        changed = True
            clusters.append(cluster)

        best: Tuple[List[StickerCandidate], float] | None = None
        image_center = np.array([width / 2.0, height / 2.0], dtype=np.float32)

        for cluster_indices in clusters:
            cluster_candidates = [candidates[idx] for idx in cluster_indices]
            sticker_count = len(cluster_candidates)
            color_count = len({candidate.color for candidate in cluster_candidates})
            if sticker_count < 3 or color_count < 3:
                continue

            x1 = min(candidate.bbox[0] for candidate in cluster_candidates)
            y1 = min(candidate.bbox[1] for candidate in cluster_candidates)
            x2 = max(candidate.bbox[2] for candidate in cluster_candidates)
            y2 = max(candidate.bbox[3] for candidate in cluster_candidates)
            bbox_w = max(1.0, float(x2 - x1))
            bbox_h = max(1.0, float(y2 - y1))
            bbox_area = bbox_w * bbox_h
            fill_ratio = min(1.0, sum(candidate.area for candidate in cluster_candidates) / bbox_area)
            aspect_penalty = abs(1.0 - (bbox_w / bbox_h))
            center = np.array([(x1 + x2) / 2.0, (y1 + y2) / 2.0], dtype=np.float32)
            center_bias = float(np.linalg.norm(center - image_center) / max(width, height))

            score = (
                sticker_count * 1.3
                + color_count * 1.1
                + fill_ratio * 3.2
                - aspect_penalty * 1.5
                - center_bias * 0.7
            )
            confidence = max(
                0.0,
                min(
                    1.0,
                    0.08 * sticker_count + 0.12 * color_count + 0.65 * fill_ratio - 0.18 * aspect_penalty,
                ),
            )
            if best is None or score > best[1]:
                best = (cluster_candidates, confidence)

        return best

    def _is_neighbor(self, a: StickerCandidate, b: StickerCandidate) -> bool:
        """Return True when two stickers are close enough to belong to one cube cluster."""
        dx = a.center[0] - b.center[0]
        dy = a.center[1] - b.center[1]
        distance = float(np.hypot(dx, dy))
        threshold = 2.35 * max(a.side, b.side)
        return distance <= threshold

    def _empty_detection(self) -> Dict[str, object]:
        return {
            "detected": False,
            "confidence": 0.0,
            "color_count": 0,
            "colors": [],
            "sticker_count": 0,
            "center_norm": None,
            "bbox_px": None,
            "size_fraction": 0.0,
            "centered": False,
            "horizontal_position": "missing",
            "vertical_position": "missing",
            "last_seen_age_s": None if self._last_seen_ts is None else round(time.time() - self._last_seen_ts, 2),
        }

    def _axis_hint(self, value: float, *, negative: str, positive: str) -> str:
        if value < -0.18:
            return negative
        if value > 0.18:
            return positive
        return "center"
