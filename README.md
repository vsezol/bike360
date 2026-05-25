# Tesla-style Vision for Motorcycle

Open-source computer-vision safety system that gives a motorcyclist 360° object
awareness around the bike — fed by an **Insta360 dual-fisheye camera** mounted
on the helmet and processed in **real-time on an iPhone**. Inspired by Tesla
Vision but built for two wheels.

> Codename: `bike360`. Currently in active development.

## Status

| Stage | What | State |
|---|---|---|
| 1 | Image processing — fisheye → flat rectilinear tiles for ML | ✅ done (this repo) |
| 2 | YOLO integration — object detection per tile, angular NMS | next |
| 3 | Gyro-based head-rotation compensation (bike-frame world coords) | planned |
| 4 | Live iOS app — 3D map of objects, approach-alert notifications | planned |

## What stage 1 does

Insta360 captures **two fisheye lenses at 190° each**. Off-the-shelf YOLO
models are trained on flat (rectilinear) images, so we convert each raw
fisheye frame into **3 flat virtual cameras** per lens (panned at −60° / 0° /
+60°), giving 6 ML-ready tiles per stereo frame with overlap zones for
cross-tile NMS.

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
ready for stage 2 (YOLO)
```

## Quick start

```bash
swift build
swift run bike360-cli extract <video.insv-renamed-to-.mp4> 100 --preprocess --undistort
```

Output: 6 PNGs in `out/`, each a flat rectilinear view of one virtual camera
(3 per lens, panned −60° / 0° / +60°).

For batch processing of a frame range:

```bash
swift run bike360-cli batch <video.mp4> <start_frame> <count> --preprocess
```

## Stack

- **Swift 6** strict concurrency mode
- **Metal** compute shaders for fisheye → rectilinear math (runs on Apple GPU)
- **Core Image** for optional preprocessing filters
- **AVFoundation** for `.insv` reading via `AVAssetReader` (zero-copy
  `CVPixelBuffer`)
- **SwiftPM** (macOS package today, iOS app target lands when full Xcode is
  installed)

## Performance

| Step | Time (debug) | Time (release) |
|---|---|---|
| Read 1 stereo frame from `.insv` | ~5 ms | ~3 ms |
| Preprocess (optional) | ~150 ms | ~30 ms |
| Undistort 6 tiles (Metal) | ~20 ms | ~5 ms |
| **Pipeline total (no disk I/O)** | **~175 ms** | **~40 ms** |

On-device target: **iPhone 15 Pro with Apple Neural Engine** for YOLO
inference. End-to-end target latency under 50 ms per stereo frame (20+ FPS
real-time).

## Why this project exists

A motorcyclist has nothing close to what a Tesla driver gets: no surround
cameras, no blind-spot AI, no adaptive cruise. Mirrors are small, head turns
are slow, and crashes happen in the seconds you weren't looking. This is a
proof-of-concept that Tesla-style visual awareness can be built on a single
360° camera + a phone in your pocket.
