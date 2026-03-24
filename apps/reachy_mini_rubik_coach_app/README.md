title: Reachy Mini Rubik Coach
emoji: 🧊
colorFrom: orange
colorTo: blue
sdk: static
pinned: false
short_description: Follow a Rubik's cube and coach the user through scan/setup steps.
suggested_storage: large
tags:
 - reachy_mini
 - reachy_mini_python_app
---

# Reachy Mini Rubik Coach

Locked Rubik's cube coaching app for Reachy Mini, built from the official conversation app pattern shown in the Reachy tutorial workflow: customize the profile, customize the tools, then publish the result.

![Reachy Mini Dance](docs/assets/reachy_mini_dance.gif)

## Table of contents
- [Overview](#overview)
- [Architecture](#architecture)
- [Installation](#installation)
- [Configuration](#configuration)
- [Running the app](#running-the-app)
- [LLM tools](#llm-tools-exposed-to-the-assistant)
- [Advanced features](#advanced-features)
- [Contributing](#contributing)
- [License](#license)

## Overview
- Real-time audio conversation loop powered by the OpenAI realtime API and `fastrtc`.
- Local Rubik's cube tracking detects a colorful cube face in the camera stream and lets Reachy follow it with head motion.
- The assistant is locked to a Rubik coach profile that instructs the user how to orient, scan, and retry steps in their companion cube app.
- Async tool dispatch combines camera inspection, cube tracking state, and robot motion through a Gradio web UI with live transcripts.

## Tutorial alignment

This app follows the same recipe described in the Reachy Mini conversation-app tutorial video:
- write the system behavior in `instructions.txt`
- expose only the tools you want in `tools.txt`
- add custom Python tool files for the new behavior
- test locally with `--gradio`
- publish with `reachy-mini-app-assistant publish`

For this version, the custom layer is a locked Rubik coach profile plus local cube tracking and scan-guidance tools.

## Architecture

The app follows a layered architecture connecting the user, AI services, and robot hardware:

<p align="center">
  <img src="docs/assets/conversation_app_arch.svg" alt="Architecture Diagram" width="600"/>
</p>

## Installation

> [!IMPORTANT]
> Before using this app, you need to install [Reachy Mini's SDK](https://github.com/pollen-robotics/reachy_mini/).<br>
> Windows support is currently experimental and has not been extensively tested. Use with caution.

<details open>
<summary><b>Using uv (recommended)</b></summary>

Set up the project quickly using [uv](https://docs.astral.sh/uv/):

```bash
# macOS (Homebrew)
uv venv --python /opt/homebrew/bin/python3.12 .venv

# Linux / Windows (Python in PATH)
uv venv --python python3.12 .venv

source .venv/bin/activate
uv sync
```

> **Note:** To reproduce the exact dependency set from this repo's `uv.lock`, run `uv sync --frozen`. This ensures `uv` installs directly from the lockfile without re-resolving or updating any versions.

**Install optional features:**
```bash
uv sync --extra local_vision         # Local PyTorch/Transformers vision
uv sync --extra yolo_vision          # YOLO-based head-tracking
uv sync --extra mediapipe_vision     # MediaPipe-based head-tracking
uv sync --extra all_vision           # All vision features
```

Combine extras or include dev dependencies:
```bash
uv sync --extra all_vision --group dev
```

</details>

<details>
<summary><b>Using pip</b></summary>

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e .
```

**Install optional features:**
```bash
pip install -e .[local_vision]          # Local vision stack
pip install -e .[yolo_vision]           # YOLO-based vision
pip install -e .[mediapipe_vision]      # MediaPipe-based vision
pip install -e .[all_vision]            # All vision features
pip install -e .[dev]                   # Development tools
```

Some wheels (like PyTorch) are large and require compatible CUDA or CPU builds—make sure your platform matches the binaries pulled in by each extra.

</details>

### Optional dependency groups

| Extra | Purpose | Notes |
|-------|---------|-------|
| `local_vision` | Run the local VLM (SmolVLM2) through PyTorch/Transformers | GPU recommended. Ensure compatible PyTorch builds for your platform. |
| `yolo_vision` | YOLOv11n head tracking via `ultralytics` and `supervision` | Runs on CPU (default). GPU improves performance. Supports the `--head-tracker yolo` option. |
| `mediapipe_vision` | Lightweight landmark tracking with MediaPipe | Works on CPU. Enables `--head-tracker mediapipe`. |
| `all_vision` | Convenience alias installing every vision extra | Install when you want the flexibility to experiment with every provider. |
| `dev` | Developer tooling (`pytest`, `ruff`, `mypy`) | Development-only dependencies. Use `--group dev` with uv or `[dev]` with pip. |

**Note:** `dev` is a dependency group (not an optional dependency). With uv, use `--group dev`. With pip, use `[dev]`.

## Configuration

1. Copy `.env.example` to `.env`
2. Fill in required values, notably the OpenAI API key

| Variable | Description |
|----------|-------------|
| `OPENAI_API_KEY` | Required. Grants access to the OpenAI realtime endpoint. |
| `MODEL_NAME` | Override the realtime model (defaults to `gpt-realtime`). Used for both conversation and vision (unless `--local-vision` flag is used). |
| `HF_HOME` | Cache directory for local Hugging Face downloads (only used with `--local-vision` flag, defaults to `./cache`). |
| `HF_TOKEN` | Optional token for Hugging Face access (for gated/private assets). |
| `LOCAL_VISION_MODEL` | Hugging Face model path for local vision processing (only used with `--local-vision` flag, defaults to `HuggingFaceTB/SmolVLM2-2.2B-Instruct`). |

## Running the app

Activate your virtual environment, then launch:

```bash
reachy-mini-rubik-coach-app
```

> [!TIP]
> Make sure the Reachy Mini daemon is running before launching the app. If you see a `TimeoutError`, it means the daemon isn't started. See [Reachy Mini's SDK](https://github.com/pollen-robotics/reachy_mini/) for setup instructions.

The app runs in console mode by default. Add `--gradio` to launch a web UI at http://127.0.0.1:7860/ (required for simulation mode). Vision and head-tracking options are described in the CLI table below.

### CLI options

| Option | Default | Description |
|--------|---------|-------------|
| `--head-tracker {yolo,mediapipe}` | `None` | Select a head-tracking backend when a camera is available. YOLO is implemented locally, MediaPipe comes from the `reachy_mini_toolbox` package. Requires the matching optional extra. |
| `--no-camera` | `False` | Run without camera capture or head tracking. |
| `--local-vision` | `False` | Use local vision model (SmolVLM2) for periodic image processing instead of gpt-realtime vision. Requires `local_vision` extra to be installed. |
| `--gradio` | `False` | Launch the Gradio web UI. Without this flag, runs in console mode. Required when running in simulation mode. |
| `--robot-name` | `None` | Optional. Connect to a specific robot by name when running multiple daemons on the same subnet. See [Multiple robots on the same subnet](#advanced-features). |
| `--debug` | `False` | Enable verbose logging for troubleshooting. |

### Examples

```bash
# Run with the built-in Rubik's cube tracker
reachy-mini-rubik-coach-app --head-tracker rubiks_cube

# Run with local vision processing (requires local_vision extra)
reachy-mini-rubik-coach-app --local-vision

# Audio-only conversation (no camera)
reachy-mini-rubik-coach-app --no-camera

# Launch with Gradio web interface
reachy-mini-rubik-coach-app --gradio
```

## LLM tools exposed to the assistant

| Tool | Action | Dependencies |
|------|--------|--------------|
| `focus_on_cube` | Enable or disable Rubik's cube following. | Core install only. |
| `cube_status` | Return whether the cube is visible and where it is in frame. | Core install only. |
| `move_head` | Queue a head pose change (left/right/up/down/front). | Core install only. |
| `camera` | Capture the latest camera frame and send it to gpt-realtime for vision analysis. | Requires camera worker. Uses gpt-realtime vision by default. |
| `head_tracking` | Built-in generic tracking toggle. Not exposed by the locked Rubik profile. | Camera worker with configured head tracker (`--head-tracker`). |
| `dance` | Queue a dance from `reachy_mini_dances_library`. | Core install only. |
| `stop_dance` | Clear queued dances. | Core install only. |
| `play_emotion` | Play a recorded emotion clip via Hugging Face datasets. | Core install only. Uses the default open emotions dataset: [`pollen-robotics/reachy-mini-emotions-library`](https://huggingface.co/datasets/pollen-robotics/reachy-mini-emotions-library). |
| `stop_emotion` | Clear queued emotions. | Core install only. |
| `do_nothing` | Explicitly remain idle. | Core install only. |

## Advanced features

Built-in motion content is published as open Hugging Face datasets:
- Emotions: [`pollen-robotics/reachy-mini-emotions-library`](https://huggingface.co/datasets/pollen-robotics/reachy-mini-emotions-library)
- Dances: [`pollen-robotics/reachy-mini-dances-library`](https://huggingface.co/datasets/pollen-robotics/reachy-mini-dances-library)

<details>
<summary><b>Custom profiles</b></summary>

Create custom profiles with dedicated instructions and enabled tools.

Set `REACHY_MINI_CUSTOM_PROFILE=<name>` to load `src/reachy_mini_rubik_coach_app/profiles/<name>/` (see `.env.example`). If unset, the `default` profile is used.

Each profile should include `instructions.txt` (prompt text). `tools.txt` (list of allowed tools) is recommended. If missing for a non-default profile, the app falls back to `profiles/default/tools.txt`. Profiles can optionally contain custom tool implementations.

**Custom instructions:**

Write plain-text prompts in `instructions.txt`. To reuse shared prompt pieces, add lines like:
```
[passion_for_lobster_jokes]
[identities/witty_identity]
```
Each placeholder pulls the matching file under `src/reachy_mini_rubik_coach_app/prompts/` (nested paths allowed). See `src/reachy_mini_rubik_coach_app/profiles/example/` for a reference layout.

**Enabling tools:**

List enabled tools in `tools.txt`, one per line. Prefix with `#` to comment out:
```
play_emotion
# move_head

# My custom tool defined locally
sweep_look
```
Tools are resolved first from Python files in the profile folder (custom tools), then from the core library `src/reachy_mini_rubik_coach_app/tools/` (like `dance`, `head_tracking`).

**Custom tools:**

On top of built-in tools found in the core library, you can implement custom tools specific to your profile by adding Python files in the profile folder.
Custom tools must subclass `reachy_mini_rubik_coach_app.tools.core_tools.Tool` (see `profiles/example/sweep_look.py`).

**Edit personalities from the UI:**

When running with `--gradio`, open the "Personality" accordion:
- Select among available profiles (folders under `src/reachy_mini_rubik_coach_app/profiles/`) or the built‑in default.
- Click "Apply" to update the current session instructions live.
- Create a new personality by entering a name and instructions text. It stores files under `profiles/<name>/` and copies `tools.txt` from the `default` profile.

Note: The "Personality" panel updates the conversation instructions. Tool sets are loaded at startup from `tools.txt` and are not hot‑reloaded.

</details>

<details>
<summary><b>Locked profile mode</b></summary>

To create a locked variant of the app that cannot switch profiles, edit `src/reachy_mini_rubik_coach_app/config.py` and set the `LOCKED_PROFILE` constant to the desired profile name:
```python
LOCKED_PROFILE: str | None = "mars_rover"  # Lock to this profile
```
When `LOCKED_PROFILE` is set, the app always uses that profile, ignoring `REACHY_MINI_CUSTOM_PROFILE` env var & the Gradio UI shows "(locked)" and disables all profile editing controls.
This is useful for creating dedicated clones of the app with a fixed personality. Clone scripts can simply edit this constant to lock the variant.

This Rubik coach app already ships in locked mode with `LOCKED_PROFILE = "rubiks_cube_coach"`.

</details>

<details>
<summary><b>External profiles and tools</b></summary>

You can extend the app with profiles/tools stored outside `src/reachy_mini_rubik_coach_app/`.

- Core profiles are under `src/reachy_mini_rubik_coach_app/profiles/`.
- Core tools are under `src/reachy_mini_rubik_coach_app/tools/`.

**Recommended layout:**

```text
external_content/
├── external_profiles/
│   └── my_profile/
│       ├── instructions.txt
│       ├── tools.txt        # optional (see fallback behavior below)
│       └── voice.txt        # optional
└── external_tools/
    └── my_custom_tool.py
```

**Environment variables:**

Set these values in your `.env` (copy from `.env.example`):

```env
REACHY_MINI_CUSTOM_PROFILE=my_profile
REACHY_MINI_EXTERNAL_PROFILES_DIRECTORY=./external_content/external_profiles
REACHY_MINI_EXTERNAL_TOOLS_DIRECTORY=./external_content/external_tools
# Optional convenience mode:
# AUTOLOAD_EXTERNAL_TOOLS=1
```

**Loading behavior:**

- **Default/strict mode**: `tools.txt` defines enabled tools explicitly. Every name in `tools.txt` must resolve to either a built-in tool (`src/reachy_mini_rubik_coach_app/tools/`) or an external tool module in `REACHY_MINI_EXTERNAL_TOOLS_DIRECTORY`.
- **Convenience mode** (`AUTOLOAD_EXTERNAL_TOOLS=1`): all valid `*.py` tool files in `REACHY_MINI_EXTERNAL_TOOLS_DIRECTORY` are auto-added.
- **External profile fallback**: if the selected external profile has no `tools.txt`, the app falls back to built-in `profiles/default/tools.txt`.

This supports both:
1. Downloaded external tools used with built-in/default profile.
2. Downloaded external profiles used with built-in default tools.

</details>

<details>
<summary><b>Multiple robots on the same subnet</b></summary>

If you run multiple Reachy Mini daemons on the same network, use:

```bash
reachy-mini-rubik-coach-app --robot-name <name>
```

`<name>` must match the daemon's `--robot-name` value so the app connects to the correct robot.

</details>

## Contributing

We welcome bug fixes, features, profiles, and documentation improvements. Please review our
[contribution guide](CONTRIBUTING.md) for branch conventions, quality checks, and PR workflow.

Quick start:
- Fork and clone the repo
- Follow the [installation steps](#installation) (include the `dev` dependency group)
- Run contributor checks listed in [CONTRIBUTING.md](CONTRIBUTING.md)

## License

Apache 2.0
