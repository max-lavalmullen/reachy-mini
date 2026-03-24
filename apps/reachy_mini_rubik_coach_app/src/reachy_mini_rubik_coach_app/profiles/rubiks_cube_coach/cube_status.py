import logging
from typing import Any, Dict

from reachy_mini_rubik_coach_app.tools.core_tools import Tool, ToolDependencies


logger = logging.getLogger(__name__)


class CubeStatus(Tool):
    """Return the latest Rubik's cube tracking state."""

    name = "cube_status"
    description = "Report whether a Rubik's cube is currently visible and where it is in the camera frame."
    parameters_schema = {
        "type": "object",
        "properties": {},
        "required": [],
    }

    async def __call__(self, deps: ToolDependencies, **kwargs: Any) -> Dict[str, Any]:
        """Get the latest tracking state."""
        if deps.camera_worker is None:
            return {"detected": False, "error": "Camera worker not available"}

        tracker = getattr(deps.camera_worker, "head_tracker", None)
        if tracker is None or not hasattr(tracker, "get_status"):
            return {"detected": False, "error": "Rubik tracker not available"}

        status = tracker.get_status()
        logger.info("Tool call: cube_status detected=%s confidence=%s", status.get("detected"), status.get("confidence"))
        return status
