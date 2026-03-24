import cv2
import numpy as np

from reachy_mini_rubik_coach_app.vision.rubiks_cube_tracker import HeadTracker


def _synthetic_cube_frame() -> np.ndarray:
    frame = np.zeros((480, 640, 3), dtype=np.uint8)
    frame[:] = (18, 18, 18)

    stickers = [
        ((250, 150), (295, 195), (0, 0, 255)),       # red
        ((302, 150), (347, 195), (0, 165, 255)),     # orange
        ((354, 150), (399, 195), (0, 255, 255)),     # yellow
        ((250, 202), (295, 247), (0, 255, 0)),       # green
        ((302, 202), (347, 247), (255, 0, 0)),       # blue
        ((354, 202), (399, 247), (255, 255, 255)),   # white
    ]
    for top_left, bottom_right, color in stickers:
        cv2.rectangle(frame, top_left, bottom_right, color, thickness=-1)
    return frame


def test_rubiks_cube_tracker_detects_cluster() -> None:
    tracker = HeadTracker()
    center, roll = tracker.get_head_position(_synthetic_cube_frame())
    status = tracker.get_status()

    assert center is not None
    assert roll == 0.0
    assert status["detected"] is True
    assert status["sticker_count"] >= 4
    assert status["color_count"] >= 4
    assert isinstance(status["bbox_px"], tuple)


def test_rubiks_cube_tracker_reports_missing_cube() -> None:
    tracker = HeadTracker()
    center, roll = tracker.get_head_position(np.zeros((480, 640, 3), dtype=np.uint8))
    status = tracker.get_status()

    assert center is None
    assert roll is None
    assert status["detected"] is False
