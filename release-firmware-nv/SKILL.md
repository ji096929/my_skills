---
name: release-firmware-nv
description: Prepare, regression-test, and push firmware NV Docker images from git tags using a runtime-only staged rootfs and a Dockerfile-driven build. Use when releasing a new firmware-nv tag such as v1.0.6-beta.5.
---

# Release Firmware NV

## Intent

Use this skill when publishing a new `firmware-nv` image from the local capture repo.

The workflow is tag-driven and split into three phases:
1. `prepare`: detect previous tag, diff changed files, rebuild only changed runtime artifacts, stage a runtime-only rootfs, and build a local Docker image.
2. `regression`: recreate `my_realtime_container` from the prepared local image, restart `glzn-all-services.service`, and run one capture.
3. `push`: tag and push the prepared local image to Harbor.

Do not skip straight to `push` unless the user explicitly asks to skip regression.
After `prepare`, summarize the changed files, rebuilt artifacts, local image tag, and next commands, then ask the user whether to run regression and whether to push.

## Quick Use

Prepare a release from the tagged commit at `HEAD`:

```bash
/home/nvidia/.codex/skills/release-firmware-nv/scripts/release_firmware_nv.sh prepare --tag v1.0.6-beta.5
```

Run the minimum regression set after user approval:

```bash
/home/nvidia/.codex/skills/release-firmware-nv/scripts/release_firmware_nv.sh regression --tag v1.0.6-beta.5
```

Push after user approval:

```bash
/home/nvidia/.codex/skills/release-firmware-nv/scripts/release_firmware_nv.sh push --tag v1.0.6-beta.5
```

Delete an existing immutable Harbor tag before push:

```bash
/home/nvidia/.codex/skills/release-firmware-nv/scripts/release_firmware_nv.sh push \
  --tag v1.0.6-beta.5 \
  --delete-existing-tag \
  --harbor-user 'firmware@1484086729164855' \
  --harbor-password '<password>'
```

## What The Script Does

### `prepare`

- Requires the repo to be clean by default.
- Requires `--tag` to point at `HEAD` by default.
- Normalizes mixed tag names such as `nvidia_v1.0.6-beta.4` and `v1.0.6-beta.5` to the same release line.
- Chooses the previous tag from that normalized release line.
- Uses the previous release image as the base image when available.
- Harvests only runtime-relevant files from the base image into `.release/firmware-nv/stage/rootfs`.
- Rebuilds only changed runtime artifacts:
  - `GLZN_CapturePrj/**` -> `GLZN_CAPTURE_APP`
  - `oss_uploader/**` -> `oss_uploader/build/oss_uploader`
  - runtime `scripts/*.sh` -> synced as shell scripts
  - `scripts/*.py` and `vendor/**/*.py` -> compiled to CPython 3.10 `.so` when appropriate
  - `displayd/**` -> `displayd/build/glzn-displayd`
- Builds a local Docker image through the repo `Dockerfile`.
- Writes release metadata under `.release/firmware-nv/<tag>/`.

### `regression`

- Stops `glzn-all-services.service`.
- Recreates `my_realtime_container` from the prepared local image with the standard runtime command used on this device:

```bash
docker run --runtime nvidia -d \
  --name my_realtime_container \
  --network=host \
  --privileged \
  --ipc=host \
  -v /dev:/dev \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /data:/data \
  -v /data/glzn/config:/home/nvidia/glzn/realtime_yuyv2h264_orbbec_color/config \
  -v /data/glzn/log:/home/nvidia/glzn/realtime_yuyv2h264_orbbec_color/log \
  -v /data/glzn/camera_calib:/home/nvidia/glzn/realtime_yuyv2h264_orbbec_color/camera_calib \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,utility,video,graphics \
  -w /home/nvidia/glzn/realtime_yuyv2h264_orbbec_color \
  <image> \
  tail -f /dev/null
```
- Restarts `glzn-all-services.service`.
- Waits for `GLZN_CAPTURE_APP` and `auto_capture_pico_main.py`.
- Runs one capture through the local WebSocket control path.
- Verifies that a new capture session with `.mp4` output exists under `/data/capture`.

### `push`

- Tags the prepared local image with the Harbor target tag.
- Optionally deletes the existing Harbor tag first.
- Pushes the image and prints the config digest.

## Preconditions

Before using this skill:
1. Check out the intended release commit locally.
2. Create the git tag on that commit.
3. Ensure the repo is clean, unless the user explicitly wants `--allow-dirty`.
4. Ensure Docker is available.
5. For `regression`, ensure the host service and container model are the expected ones for this device.
6. For `push`, ensure Harbor credentials are available if immutable tags require deletion.

## Files

Primary script:

- `/home/nvidia/.codex/skills/release-firmware-nv/scripts/release_firmware_nv.sh`

Primary repo Dockerfile used by the release build:

- `/home/nvidia/Desktop/realtime_yuyv2h264_orbbec_color/Dockerfile`

## Expected Output

### After `prepare`

The script prints:
- normalized target tag
- previous tag
- base image
- local image tag
- local image id
- staged rootfs location
- changed files list path
- build actions list path
- staged artifacts list path

### After `regression`

The script prints:
- service name
- container name
- local image tag
- capture validation result

### After `push`

The script prints:
- git head
- remote image
- config digest
