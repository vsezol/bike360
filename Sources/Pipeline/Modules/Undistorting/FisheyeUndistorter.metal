#include <metal_stdlib>
using namespace metal;

struct RectilinearParams {
  float inputFocal;
  float inputCx;
  float inputCy;
  float inputWidth;
  float inputHeight;
  float inputMaxThetaRadians;
  float outputFocal;
  float outputWidth;
  float outputHeight;
  float tileYawRadians;
  float tilePitchRadians;
};

struct EquirectParams {
  float inputFocal;
  float inputCx;
  float inputCy;
  float inputWidth;
  float inputHeight;
  float inputMaxThetaRadians;
  float outputWidth;
  float outputHeight;
  float outputFovHorizontalRadians;
  float outputFovVerticalRadians;
};

struct StereographicParams {
  float inputFocal;
  float inputCx;
  float inputCy;
  float inputWidth;
  float inputHeight;
  float inputMaxThetaRadians;
  float outputFocal;
  float outputWidth;
  float outputHeight;
};

constant sampler bilinearSampler(coord::normalized,
                                  address::clamp_to_edge,
                                  filter::linear);

// Rectilinear ("pinhole") projection of a fisheye view, with horizontal
// yaw so several tiles can be stitched to cover >180°. Kept for cases
// where YOLO benefits from a true rectilinear input (no spherical warp),
// at the cost of losing >FOV/2 from the lens.
kernel void undistortFisheyeEquidistant(
  texture2d<float, access::sample> inputTex      [[texture(0)]],
  texture2d<float, access::write>  outputTex     [[texture(1)]],
  constant RectilinearParams&      params        [[buffer(0)]],
  uint2                            gid           [[thread_position_in_grid]]
) {
  uint outW = outputTex.get_width();
  uint outH = outputTex.get_height();
  if (gid.x >= outW || gid.y >= outH) {
    return;
  }

  float halfW = params.outputWidth * 0.5;
  float halfH = params.outputHeight * 0.5;
  float x = (float(gid.x) + 0.5 - halfW) / params.outputFocal;
  float y = (float(gid.y) + 0.5 - halfH) / params.outputFocal;
  float z = 1.0;

  float len = sqrt(x * x + y * y + z * z);
  x /= len; y /= len; z /= len;

  // Pitch (rotation around X axis): positive = virtual camera aims UP.
  // Image coords have +Y down, so rotating "up" subtracts sin(pitch) from y.
  float cosP = cos(params.tilePitchRadians);
  float sinP = sin(params.tilePitchRadians);
  float xp = x;
  float yp = y * cosP - z * sinP;
  float zp = y * sinP + z * cosP;

  // Yaw (rotation around Y axis): positive = pan RIGHT.
  float cosY = cos(params.tileYawRadians);
  float sinY = sin(params.tileYawRadians);
  float xr = xp * cosY + zp * sinY;
  float yr = yp;
  float zr = -xp * sinY + zp * cosY;

  if (zr <= 0.0) {
    outputTex.write(float4(0.0, 0.0, 0.0, 1.0), gid);
    return;
  }
  float theta = acos(zr);
  if (theta > params.inputMaxThetaRadians) {
    outputTex.write(float4(0.0, 0.0, 0.0, 1.0), gid);
    return;
  }

  float phi = atan2(yr, xr);
  float r_in = params.inputFocal * theta;
  float u_in = params.inputCx + r_in * cos(phi);
  float v_in = params.inputCy + r_in * sin(phi);

  float2 uv = float2(u_in / params.inputWidth, v_in / params.inputHeight);
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    outputTex.write(float4(0.0, 0.0, 0.0, 1.0), gid);
    return;
  }

  float4 color = inputTex.sample(bilinearSampler, uv);
  outputTex.write(color, gid);
}

// Equirectangular projection of a fisheye hemisphere — each output pixel is
// a (longitude, latitude) direction relative to the lens optical axis.
// Covers the full input FOV in a single image with no rectilinear FOV cap,
// no clipped corners, and minimal stretching near the optical axis.
// Distortion grows toward the lens edges (the "poles" of the projection)
// but every pixel of the fisheye is preserved — nothing is lost.
kernel void equirectangularFromFisheye(
  texture2d<float, access::sample> inputTex      [[texture(0)]],
  texture2d<float, access::write>  outputTex     [[texture(1)]],
  constant EquirectParams&         params        [[buffer(0)]],
  uint2                            gid           [[thread_position_in_grid]]
) {
  uint outW = outputTex.get_width();
  uint outH = outputTex.get_height();
  if (gid.x >= outW || gid.y >= outH) {
    return;
  }

  // Output pixel -> (longitude, latitude) within the configured FOV box.
  // longitude: horizontal angle around the lens axis (Y rotation)
  // latitude:  vertical angle around the lens axis (X rotation)
  float lon = ((float(gid.x) + 0.5) / params.outputWidth - 0.5) * params.outputFovHorizontalRadians;
  float lat = (0.5 - (float(gid.y) + 0.5) / params.outputHeight) * params.outputFovVerticalRadians;

  // Spherical -> 3D unit vector in lens camera coords (+Z = optical axis,
  // +Y = world up). Image pixel coords have +Y pointing DOWN, so we
  // flip the sign of y when computing the fisheye azimuth below.
  float cosLat = cos(lat);
  float x = cosLat * sin(lon);
  float y = sin(lat);
  float z = cosLat * cos(lon);

  // Rays behind the lens are not in this hemisphere.
  if (z <= 0.0) {
    outputTex.write(float4(0.0, 0.0, 0.0, 1.0), gid);
    return;
  }

  float theta = acos(z);
  if (theta > params.inputMaxThetaRadians) {
    outputTex.write(float4(0.0, 0.0, 0.0, 1.0), gid);
    return;
  }

  // Fisheye image uses +Y down, but our 3D +Y is up — invert.
  float phi = atan2(-y, x);
  float r_in = params.inputFocal * theta;
  float u_in = params.inputCx + r_in * cos(phi);
  float v_in = params.inputCy + r_in * sin(phi);

  float2 uv = float2(u_in / params.inputWidth, v_in / params.inputHeight);
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    outputTex.write(float4(0.0, 0.0, 0.0, 1.0), gid);
    return;
  }

  float4 color = inputTex.sample(bilinearSampler, uv);
  outputTex.write(color, gid);
}

// Stereographic projection of a fisheye hemisphere. Conformal — locally
// preserves angles, so shapes of objects (cars, signs, buildings) stay
// recognisable instead of being stretched into pincushions like in
// equirectangular, or clipped at the rectilinear FOV wall.
//
// Geometry: project the unit sphere from its south pole onto the plane
// tangent at the north pole. A direction at angle theta from the optical
// axis lands on the plane at radius r = 2 * tan(theta / 2). Inverse:
// theta = 2 * atan(r / 2). Objects near the lens edge become smaller
// but stay shape-correct — ideal when YOLO needs intact object outlines.
kernel void stereographicFromFisheye(
  texture2d<float, access::sample> inputTex      [[texture(0)]],
  texture2d<float, access::write>  outputTex     [[texture(1)]],
  constant StereographicParams&    params        [[buffer(0)]],
  uint2                            gid           [[thread_position_in_grid]]
) {
  uint outW = outputTex.get_width();
  uint outH = outputTex.get_height();
  if (gid.x >= outW || gid.y >= outH) {
    return;
  }

  float halfW = params.outputWidth * 0.5;
  float halfH = params.outputHeight * 0.5;
  float x = (float(gid.x) + 0.5 - halfW) / params.outputFocal;
  float y = (float(gid.y) + 0.5 - halfH) / params.outputFocal;

  float r = sqrt(x * x + y * y);
  float theta = 2.0 * atan(r * 0.5);

  if (theta > params.inputMaxThetaRadians) {
    outputTex.write(float4(0.0, 0.0, 0.0, 1.0), gid);
    return;
  }

  float phi = atan2(y, x);
  float r_in = params.inputFocal * theta;
  float u_in = params.inputCx + r_in * cos(phi);
  float v_in = params.inputCy + r_in * sin(phi);

  float2 uv = float2(u_in / params.inputWidth, v_in / params.inputHeight);
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    outputTex.write(float4(0.0, 0.0, 0.0, 1.0), gid);
    return;
  }

  float4 color = inputTex.sample(bilinearSampler, uv);
  outputTex.write(color, gid);
}

