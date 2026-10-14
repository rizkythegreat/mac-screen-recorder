# Studio

A small local-first screen recorder for macOS 15+, modeled on Screen Studio's core loop:
record → automatic zooms on clicks → smooth cursor → trim/cut/speed → export MP4.
No dependencies, no network.

```sh
./build.sh            # runs the self-test, builds build/Studio.app
open build/Studio.app
```

First recording asks for **Screen Recording** (and **Microphone** if enabled) in System Settings → Privacy & Security.
Quit and reopen Studio after granting. The ad-hoc signature makes macOS ask again after every rebuild;
set `SIGN_IDENTITY="Apple Development: …"` when running `build.sh` to keep the permission.

## Use

- **Record screen** (⇧⌘R) opens setup: choose a screen or window, inspect its refreshed preview, select a microphone and check the live input meter. Start after a 3-second countdown; Cancel stops the countdown. Studio's own windows are left out. Stop with the same button.
- While recording: **Pause / Resume** (⇧⌘P), **Stop** (⇧⌘R), **Restart** and **Cancel** (both delete the take after asking) — on the Home card and in the menu bar icon (Studio's window is hidden from the capture). Paused time is cut from every track and the cursor log, so the file has no gap.
- Window capture follows the selected window. Cursor tracking follows its position and hides the cursor outside the captured source. Refresh the source/device list after connecting hardware or opening a new window.
- Enable **Webcam** in recording setup, choose a camera, and check its live mirrored preview. The first use asks for Camera permission. Webcam is saved separately and stays synchronized through trims, cuts, and speed changes.
- **Webcam inspector**: show/hide the camera, choose Circle / Rounded / Square, mirror, resize, and position it with corner buttons or sliders. The overlay stays fixed while the screen zooms; preview and export use the same rendering. Existing recordings without a camera remain unchanged.
- The editor opens with zooms already placed on your clicks.
- **Undo / Redo** (⌘Z / ⇧⌘Z): restore edits during the current editor session; a slider drag is one edit.
- **Trim**: select a clip, then drag its left or right handle. Drag outward to restore trimmed footage. Thumbnails, a time ruler, and timeline zoom help locate edits; scroll horizontally on longer recordings.
- **Split** (⌘B) cuts the clip at the playhead; select a clip to delete it or change its speed. With a zoom selected, ⌘B splits that zoom instead; each half keeps its own level and focus.
- **Add zoom** (⌥⌘Z); select a zoom to change level, start/end, or disable it.
- Inspector tabs (left rail): Background, Appearance, Cursor, Webcam, Canvas, Zooms, Presets.
- Cursor: choose a shape, then a color. As recorded or 48 drawn looks (Classic, Rounded, Slim, Pixel, Outline, and Gradient in 8 colors; replaces every recorded shape), size, motion blur (sharp cursor with a trail of its last frame), smoothing, and selectable click effects (soft glow, expanding ring, cursor press, or none).
- **Style presets**: choose Signature, Clean slate, Midnight, or Warm studio; save your own named style for reuse across recordings. Background images are copied with the preset. Apply a preset as one undoable edit; delete saved presets through the nearby menu.
- **Canvas**: landscape 16:9, portrait 9:16, or square 1:1. Fit shows the full recording; Fill crops it to the padded canvas. Adjust horizontal/vertical position; each format remembers its own framing. Preview and export match.
- Background: gradient presets or custom colors, your wallpaper, or any image (copied into the recording folder), with blur.
- **Export…** (⌘E): HD / Full HD / 4K, H.264 or HEVC, 60 fps MP4. Quality sets the short edge to 720 / 1080 / 2160 px (Full HD portrait is 1080×1920; square is 1080×1080). A progress sheet shows percent, time left and a Cancel button (which deletes the partial file); the Dock icon shows the percent. When done: file size, Show in Finder, Open; on failure: the error and Try again.

Custom style presets live in `~/Library/Application Support/Studio/Presets/`. Canvas settings are saved with each project; existing projects retain their original landscape layout.

Recordings live in `~/Movies/Studio/<Recording …>/`:
`screen.mov` (HEVC, no cursor), `system.m4a`, `mic.m4a`, `recording.json` (cursor samples, clicks, offsets),
`cursors/*.png`, optional `webcam.mov`, `project.json` (your edits).

## How it works

| File | Role |
|---|---|
| `CaptureSetup.swift` | Source picker, screenshot preview, microphone check, and countdown |
| `Webcam.swift` | Camera session, preview, host-clock timestamps, and shared picture-in-picture rendering |
| `Recorder.swift` | ScreenCaptureKit (`showsCursor = false`), one `AVAssetWriter` per stream, 60 Hz cursor sampling + click monitor |
| `Motion.swift` | Auto-zoom rule, move groups, clamped springs, camera/cursor timeline, cut/speed time mapping |
| `Renderer.swift` | Custom `AVVideoCompositing` (Core Image) shared by preview and export; composition building; export |
| `App.swift` | SwiftUI library, editor, and Edit menu |
| `Timeline.swift` | Thumbnail timeline, ruler, and draggable trim handles |
| `Canvas.swift` | Format dimensions and shared fit/fill positioning |
| `StylePresets.swift` | Built-in styles and portable custom preset storage |
| `Editing.swift` | Bounded undo/redo history and nondestructive trim rules |
| `SelfTest.swift` | `Studio --selftest`, `Studio --render-test <dir>` and `Studio --record-test` (live capture with a pause; needs Screen Recording) (synthetic recording → real export → PNG frames) |

Numbers taken from Screen Studio 4.0.4: zoom window `[click-0.3s, click+2.5s]`, merge gap 2.5 s, zoom 2×,
move groups spanning ≤ 50% of the screen. The camera uses a near-critically damped spring
(stiffness 170 / damping 32 / mass 1.5) with continuous timeline sampling.
The cursor deliberately differs: it uses a zero-lag 80 ms Gaussian over the whole path instead of a spring,
to avoid the lag of a causal cursor spring. Fractional timestamps interpolate between motion samples,
including slow-motion edits. Click glows ease in and out over 550 ms of playback time, with a subtle
cursor press anchored at the hotspot.

## Not included (yet)

iPhone screen recording, keystroke capture / typing-aware camera, camera (zoom/pan) motion blur, cursor idle-hide,
audio cleanup, captions, GIF export, share links.

Cursor style inspiration: [OpenScreen’s theme library](https://github.com/siddharthvaddem/openscreen/blob/main/src/lib/cursor/cursorThemes.ts). Studio draws its cursor styles locally with Core Graphics; no third-party cursor artwork is bundled.
