import logging
from typing import Any, Dict, List

from reachy_mini_rubik_coach_app.tools.core_tools import Tool, ToolDependencies


logger = logging.getLogger(__name__)


class CubeGuidance(Tool):
    """Return simple positioning guidance derived from the tracker state."""

    name = "cube_guidance"
    description = "Give short positioning guidance so the user can center the Rubik's cube for scanning."
    parameters_schema = {
        "type": "object",
        "properties": {
            "purpose": {
                "type": "string",
                "enum": ["center_for_scan", "recover_cube"],
                "description": "Why you need guidance right now.",
            },
        },
        "required": [],
    }

    async def __call__(self, deps: ToolDependencies, purpose: str = "center_for_scan", **kwargs: Any) -> Dict[str, Any]:
        """Get a short scan-oriented coaching hint."""
        if deps.camera_worker is None:
            return {"detected": False, "instruction": "Camera worker not available."}

        tracker = getattr(deps.camera_worker, "head_tracker", None)
        if tracker is None or not hasattr(tracker, "get_status"):
            return {"detected": False, "instruction": "Rubik tracker not available."}

        status = tracker.get_status()
        if not status.get("detected"):
            instruction = "I can't see the cube yet. Bring it back in front of Reachy and hold it steady."
            if purpose == "recover_cube":
                instruction = "The cube is out of frame. Bring it back to the center and pause for a moment."
            return {"detected": False, "instruction": instruction, "status": status}

        center_x, center_y = status.get("center_norm") or (0.0, 0.0)
        size_fraction = float(status.get("size_fraction") or 0.0)
        steps: List[str] = []

        if center_x < -0.18:
            steps.append("move the cube a little to your right")
        elif center_x > 0.18:
            steps.append("move the cube a little to your left")

        if center_y < -0.18:
            steps.append("lower the cube slightly")
        elif center_y > 0.18:
            steps.append("raise the cube slightly")

        if size_fraction < 0.04:
            steps.append("bring it a bit closer")
        elif size_fraction > 0.34:
            steps.append("move it slightly farther back")

        if not steps:
            instruction = "Hold that position steady. The cube is centered well enough for the next app step."
        else:
            instruction = "For the next scan step, " + ", then ".join(steps) + "."

        logger.info("Tool call: cube_guidance purpose=%s instruction=%s", purpose, instruction)
        return {
            "detected": True,
            "instruction": instruction,
            "centered": status.get("centered", False),
            "status": status,
        }
