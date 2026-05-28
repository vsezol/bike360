# Tesla-style Vision for Motorcycle

Open-source computer-vision safety system that gives a motorcyclist 360° object
awareness around the bike — fed by an **Insta360 dual-fisheye camera** mounted
on the helmet and processed in **real-time on an iPhone**. Inspired by Tesla
Vision but built for two wheels.

> Codename: `bike360`. Currently in active development.

## Status

| Stage | What | State |
|---|---|---|
| 1 | Image processing — fisheye → flat rectilinear tiles for ML | ✅ done |
| 2 | YOLO integration — object detection per tile + distance estimation | ✅ done |
| 3 | Gyro-based head-rotation compensation (bike-frame world coords) + cross-tile NMS | next |
| 4 | Live iOS app — 3D map of objects, approach-alert notifications | planned |

## What stages 1+2 do together

Insta360 captures **two fisheye lenses at 190° each**. Off-the-shelf YOLO
models are trained on flat (rectilinear) images, so we convert each raw
fisheye frame into **3 flat virtual cameras** per lens (panned at −60° / 0° /
+60°), giving 6 ML-ready tiles per stereo frame with overlap zones for
cross-tile NMS.

Each tile is then run through **YOLOv11n on Apple Neural Engine**. Detections
are filtered to traffic-relevant classes (car / truck / bus / motorcycle /
bicycle / person / traffic light / stop sign) and enriched with:

- **Angular position** (yaw + pitch) relative to the lens optical axis —
  ready to be lifted to bike-frame world coords by the gyro stage.
- **Distance estimate** in meters via the pinhole height formula and a
  class → real-world-height lookup table (car 1.5m, truck 3.5m, person
  1.7m, …). Accuracy ~10–15%, good enough for collision-distance alerts.

## Pipeline

```
.insv (2 HEVC tracks @ 60 fps)
   ↓
InsvVideoSource          read both lens tracks in parallel
   ↓ StereoFrame
PreprocessingModule      (optional) Core Image filters
   ↓ StereoFrame
UndistortingModule       Metal compute shader: fisheye → K rectilinear tiles
   ↓ TiledFrame (6 tiles)
YoloModule × 6           Vision + CoreML object detection per tile,
                         parallel via TaskGroup, ANE-routed
   ↓ [Detection]         class, confidence, bbox, yaw, pitch, distance, lens
ready for stage 3 (gyro fusion → bike-frame world coords)
```

## Quick start

```bash
swift build -c release
swift run -c release bike360-cli extract \
  <video.insv-renamed-to-.mp4> 100 --preprocess --undistort
```

Output: 6 PNGs in `out/`, each a flat rectilinear view of one virtual camera
(3 per lens, panned −60° / 0° / +60°).

### With object detection

Requires a YOLOv11n CoreML model. Export once via ultralytics:

```bash
uv run --python 3.11 --with "numpy<2" --with coremltools --with ultralytics \
  python -c "from ultralytics import YOLO; YOLO('yolo11n.pt').export(format='coreml', imgsz=640, nms=True)"
mv yolo11n.mlpackage Resources/Models/
```

Then run:

```bash
swift run -c release bike360-cli extract \
  <video.mp4> 100 --preprocess --undistort --detect
```

Adds to `out/`: a `frame_NNNNNN_detections.json` with class/confidence/angle/distance
for every detected object, plus per-tile overlay PNGs (`*_detected.png`) drawing
the bboxes with class + distance labels.

For batch processing of a frame range:

```bash
swift run -c release bike360-cli batch <video.mp4> <start_frame> <count> --preprocess
```

## Stack

- **Swift 6** strict concurrency mode
- **Metal** compute shaders for fisheye → rectilinear math (runs on Apple GPU)
- **Core Image** for optional preprocessing filters
- **AVFoundation** for `.insv` reading via `AVAssetReader` (zero-copy
  `CVPixelBuffer`)
- **Vision + CoreML** for YOLO inference; `MLModelConfiguration.computeUnits = .all`
  routes work to ANE / GPU / CPU automatically
- **YOLOv11n** (Ultralytics) exported to CoreML, COCO 80-class
- **SwiftPM** (macOS package today, iOS app target lands when full Xcode is
  installed)

## Performance (Mac M-series, release build)

| Step | Time |
|---|---|
| Read 1 stereo frame from `.insv` | ~3 ms |
| Preprocess (optional) | ~30 ms |
| Undistort 6 tiles (Metal) | ~5 ms |
| YOLO inference × 6 tiles (parallel, ANE-routed) | ~60 ms |
| **Pipeline total (no disk I/O)** | **~100 ms = 10 FPS** |

On iPhone 15 Pro with full ANE access, YOLO inference is expected to drop to
~10 ms (6 × ~2 ms parallel), giving a target end-to-end latency of **~20–30 ms
per stereo frame = 30+ FPS real-time**, well within the safety budget.

On-device target: **iPhone 15 Pro with Apple Neural Engine** for YOLO
inference. End-to-end target latency under 50 ms per stereo frame (20+ FPS
real-time).

## Why this project exists

A motorcyclist has nothing close to what a Tesla driver gets: no surround
cameras, no blind-spot AI, no adaptive cruise. Mirrors are small, head turns
are slow, and crashes happen in the seconds you weren't looking. This is a
proof-of-concept that Tesla-style visual awareness can be built on a single
360° camera + a phone in your pocket.
