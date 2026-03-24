import logging
from typing import Any, Dict

from reachy_mini_rubik_coach_app.tools.core_tools import Tool, ToolDependencies


logger = logging.getLogger(__name__)


class FocusOnCube(Tool):
    """Enable or disable Rubik's cube tracking."""

    name = "focus_on_cube"
    description = "Enable or disable Rubik's cube tracking so Reachy follows the cube with its head."
    parameters_schema = {
        "type": "object",
        "properties": {
            "enabled": {
                "type": "boolean",
                "description": "True to follow the cube, false to stop following it.",
            },
        },
        "required": ["enabled"],
    }

    async def __call__(self, deps: ToolDependencies, **kwargs: Any) -> Dict[str, Any]:
        """Toggle cube tracking."""
        enabled = bool(kwargs.get("enabled"))
        if deps.camera_worker is None:
            return {"enabled": False, "error": "Camera worker not available"}

        deps.camera_worker.set_head_tracking_enabled(enabled)
        tracker = getattr(deps.camera_worker, "head_tracker", None)
        if tracker is not None and hasattr(tracker, "set_tracking_enabled"):
            tracker.set_tracking_enabled(enabled)

        status = tracker.get_status() if tracker is not None and hasattr(tracker, "get_status") else None
        logger.info("Tool call: focus_on_cube enabled=%s", enabled)
        return {
            "enabled": enabled,
            "status": "cube tracking enabled" if enabled else "cube tracking disabled",
            "tracker": status,
        }
