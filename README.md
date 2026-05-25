# bike360

Tesla-style object detection around a motorcyclist — fed by an Insta360 dual-fisheye camera on the helmet, processed in real-time on a smartphone.

**Stage 1 (this repo, complete):** image processing — convert raw `.insv` fisheye frames into 6 flat rectilinear tiles per stereo frame, ready for off-the-shelf YOLO.

## Pipeline

```
.insv (2 HEVC tracks @ 60fps)
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

Output: 6 PNGs in `out/`, each a flat rectilinear view of one virtual camera (3 per lens, panned -60° / 0° / +60°).

## Stack

- Swift 6 strict concurrency mode
- Metal compute shaders (fisheye → rectilinear math)
- Core Image (preprocessing)
- AVFoundation (.insv reading via `AVAssetReader`)
- SwiftPM (macOS package, iOS app target lands when full Xcode is installed)

## Roadmap

- [x] Stage 1: image processing
- [ ] Stage 2: YOLO integration (Vision/CoreML, 6 inferences in parallel, angular NMS)
- [ ] Stage 3: gyro-based head rotation compensation (bike-frame world coords)
- [ ] Stage 4: live UI on iOS — 3D map of objects, approach-alert notifications
