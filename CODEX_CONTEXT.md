# Reachy Mini — Codex Handoff Context

## Project overview

Native macOS AppKit app (Objective-C + ARC, embedded CPython 3.12). Controls a Pollen Robotics
Reachy Mini robot over HTTP. Build with `make` from the repo root — produces
`ReachyControl.app`.

**Pollen's own app is MIT-licensed open source. We are intentionally copying its exact UI styling.**

---

## Architecture

- `src/AppDelegate.m` — window chrome, sidebar, panel routing
- `src/HTTPClient.{h,m}` — dual NSURLSession: `postJSON:` (5s, for fast real-time goto/polls) and `postAction:` (120s, for blocking endpoints like wake_up/goto_sleep/behavior play)
- `src/PythonBridge.{h,m}` — embedded Python 3.12 for daemon + live voice
- `src/panels/` — one NSViewController subclass per sidebar panel
- `src/widgets/JoystickView.{h,m}` — custom joystick drag widget

### Pollen dark palette (use these everywhere)
```objc
// Root background
pRGB(5, 10, 18)          // deepest dark

// Card / panel background
pRGB(14, 25, 42)         // slightly lighter

// Accent green
pRGB(61, 222, 153)       // #3DDE99

// Border
pRGBA(255, 255, 255, 0.08)  // subtle white border

// Dim text / subtext
pRGBA(202, 211, 223, 0.55)

// Normal body text
colorWithWhite:0.85
```

---

## What has been completed

### HTTPClient — dual session (CRITICAL BUG FIX)
`src/HTTPClient.m` has two sessions:
- `_session` (5s/30s) — used by `postJSON:` for `/api/move/goto` and status polls
- `_actionSession` (120s/180s) — used by `postAction:` for blocking endpoints

**Always use `postAction:` for**: `wake_up`, `goto_sleep`, any `recorded-move-dataset` play endpoint.
**Always use `postJSON:` for**: `/api/move/goto`, `/api/daemon/start`, all status GETs.

### AntennaPanel (src/panels/AntennaPanel.m)
Full rewrite as combined Controls panel:
- `AntennaKnobView` — custom circular arc drag control (atan2 mouse tracking, 30°–150° math arc = -60°..+60° antenna degrees)
- Head joystick (JoystickView) + roll slider + two antenna knobs
- **20Hz NSTimer throttle** — single `/api/move/goto` call per tick, `_headDirty`/`_antennaDirty` flags prevent queue buildup
- Head sends **radians**: pan = joystickX × 0.40, tilt = -joystickY × 0.35 (NOT degrees — degrees caused shaking at 35× scale)
- Antennas: degrees→radians on send: `leftDeg * M_PI / 180.0`

### Sidebar (src/AppDelegate.m)
Full custom restyle — no more NSVisualEffectMaterialSidebar:
- Plain dark `NSView` bg: `pRGB(10,18,32)`
- `SidebarRowView` subclass draws green accent pill + tinted bg for selected row
- `NSTableViewSelectionHighlightStyleNone` — selection drawn manually
- Header "Reachy Mini / Control Panel" with 34pt top offset (clears transparent titlebar)
- Separator: `pRGBA(255,255,255,0.07)` hairline
- Nav rows: 44pt, icon @ 20pt lead, label 12pt right; green icon+text when selected, 60%/85% white when unselected
- Sidebar items: Connection, Conversation, Camera, Controls, Motors, Behaviors, Terminal

### CameraPanel (src/panels/CameraPanel.m)
Full dark restyle — root pRGB(5,10,18), camera frame card black with cornerRadius=14, Start/Stop buttons, "● Live" status in green, FPS label.

### MotorPanel (src/panels/MotorPanel.m)
Full dark restyle — `DarkTableView` subclass overrides `backgroundColor` and `drawBackgroundInClipRect:`. Alternating row colors, temperature color-coding (green < 40°C, amber 40–50°C, red > 50°C).

### BehaviorsPanel (src/panels/BehaviorsPanel.m)
Full dark restyle + bug fix: wake_up/goto_sleep/play now use `postAction:` (was silently timing out with 5s session). Disabled buttons while in-flight.

### ChatPanel (src/panels/ChatPanel.m) — JUST COMPLETED, NOT YET COMMITTED
Colors fixed to Pollen palette:
- Root bg: `pRGB(5,10,18)`
- Chat area bg/border: `pRGB(14,25,42)` / `pRGBA(255,255,255,0.08)`
- Accent checkboxes, send button, live button: `pRGB(61,222,153)` green
- User bubbles: deep blue `rgb(30,64,130)` with blue border
- Assistant bubbles: `pRGB(14,25,42)` with `rgba(255,255,255,0.08)` border
- Transcript label: green accent
- Status label: `pRGBA(202,211,223,0.55)`
- Talk/text input: card bg with `pRGBA(255,255,255,0.12)` border
- Reset button: ghost style

**This change is built but NOT yet committed/pushed.**

---

## Git workflow

After every completed feature:
```bash
git add <files>
git commit -m "descriptive message"
git push
```

Remote: `https://github.com/max-lavalmullen/reachy-mini.git` (branch: `main`)

The ChatPanel changes are ready to commit:
```bash
git add src/panels/ChatPanel.m src/AppDelegate.m
git commit -m "Restyle ChatPanel to Pollen dark palette (green accent, card bg, borders)"
git push
```

---

## Remaining UI work (next passes)

### 1. ConnectionPanel (src/panels/ConnectionPanel.m)
Read it first — likely still has old colors. Should get same Pollen palette treatment:
- Root: `pRGB(5,10,18)`
- Cards: `pRGB(14,25,42)` with border `pRGBA(255,255,255,0.08)` and `cornerRadius=14`
- Status badge: green dot "● Connected" / red "● Disconnected"
- Wake Up / Go to Sleep buttons: green primary style

### 2. TerminalPanel (src/panels/TerminalPanel.m)
Read it first — terminal output area should be `pRGB(5,10,18)` or pure black, monospace green text `pRGB(61,222,153)`, command input with card styling.

### 3. DashboardPanel (src/panels/DashboardPanel.m)
Read it first — overview/status panel, should use same card-based dark layout.

### 4. Window titlebar / toolbar
Currently: `titlebarAppearsTransparent = YES`, `NSAppearanceNameDarkAqua`, `NSWindowToolbarStyleUnifiedCompact`. The transparent titlebar blends into the sidebar's `pRGB(10,18,32)`. May need a window title tweak or custom toolbar.

---

## Key technical gotchas

1. **Never send degrees to `/api/move/goto` head_pose** — it expects radians. Pan range ≈ ±0.40 rad, tilt ≈ ±0.35 rad.
2. **20Hz timer throttle for real-time movement** — do not send on every UI event or requests queue up and robot executes stale positions seconds later.
3. **`postAction:` vs `postJSON:`** — confusing them causes silent 5s timeouts on blocking endpoints.
4. **DarkTableView** — plain `NSTableView` ignores `backgroundColor` in some configurations; the subclass that overrides `drawBackgroundInClipRect:` is needed for proper dark backgrounds in table views.
5. **Full-size content view** — `NSWindowStyleMaskFullSizeContentView` + `titlebarAppearsTransparent` means content starts at (0,0) under the titlebar (~28pt). Account for this in any top-level layout (sidebar header uses 34pt top padding).
6. **Auto Layout everywhere** — all rewritten panels use `translatesAutoresizingMaskIntoConstraints = NO` + `NSLayoutConstraint`. Don't mix with autoresizing masks in the same view hierarchy.

---

## Build

```bash
cd ~/Desktop/reachy-mini
make
# Output: ReachyControl.app
```

No Xcode project — pure clang + Makefile. Check `Makefile` for flags. Uses:
- `-framework AppKit -framework Foundation -framework CoreGraphics -framework QuartzCore`
- `-framework Speech -framework AVFoundation -framework WebKit`
- Python 3.12 headers from `/Users/maxl/.local/share/uv/python/cpython-3.12.12-macos-aarch64-none/`
