#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  release_firmware_nv.sh [prepare|regression|push] --tag <tag> [options]

Phases:
  prepare                    Build changed artifacts from the tagged commit,
                             stage a runtime-only rootfs, and build a local image.
                             This is the default phase.
  regression                 Recreate the runtime container from the prepared local
                             image, restart glzn-all-services.service, and run one
                             capture via scripts/test/test_pico_client.py --local.
  push                       Tag and push the prepared local image to Harbor.

Required:
  --tag <tag>                Release tag at HEAD, e.g. v1.0.6-beta.5

Options:
  --repo <path>              Source repo path
                             (default: /home/nvidia/Desktop/realtime_yuyv2h264_orbbec_color)
  --registry <repo>          Registry repo without tag
                             (default: lw-ali-harbor-registry.cn-shanghai.cr.aliyuncs.com/cloud-integration/firmware-nv)
  --dockerfile <path>        Dockerfile path
                             (default: <repo>/Dockerfile)
  --container <name>         Runtime container name
                             (default: my_realtime_container)
  --container-root <path>    Project root inside container
                             (default: /home/nvidia/glzn/realtime_yuyv2h264_orbbec_color)
  --service <name>           Host systemd service used for regression
                             (default: glzn-all-services.service)
  --base-image <image>       Override the base image used for prepare
  --allow-dirty              Allow prepare from a dirty worktree
  --allow-tag-off-head       Allow prepare when --tag does not point at HEAD
  --delete-existing-tag      Delete existing Harbor tag before push
  --harbor-user <user>       Harbor username used by --delete-existing-tag
                             (or env HARBOR_USER)
  --harbor-password <pass>   Harbor password used by --delete-existing-tag
                             (or env HARBOR_PASSWORD)
  -h, --help                 Show help

Outputs:
  .release/firmware-nv/stage/rootfs/            Runtime-only staged filesystem
  .release/firmware-nv/<tag>/release.env        Metadata for regression/push
  .release/firmware-nv/<tag>/*.txt              Changed files, actions, artifacts
USAGE
}

REPO_PATH="/home/nvidia/Desktop/realtime_yuyv2h264_orbbec_color"
REGISTRY_REPO="lw-ali-harbor-registry.cn-shanghai.cr.aliyuncs.com/cloud-integration/firmware-nv"
DOCKERFILE_PATH=""
CONTAINER_NAME="my_realtime_container"
CONTAINER_ROOT="/home/nvidia/glzn/realtime_yuyv2h264_orbbec_color"
SERVICE_NAME="glzn-all-services.service"
TARGET_TAG=""
PHASE="prepare"
ALLOW_DIRTY=0
ALLOW_TAG_OFF_HEAD=0
DELETE_EXISTING_TAG=0
HARBOR_USER="${HARBOR_USER:-}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-}"
BASE_IMAGE_OVERRIDE=""

STATE_ROOT_REL=".release/firmware-nv"
STATE_ROOT=""
STAGE_ROOT=""
TAG_STATE_DIR=""
METADATA_FILE=""
CHANGED_LIST_FILE=""
ACTIONS_LIST_FILE=""
ARTIFACT_LIST_FILE=""
STAGE_APP_ROOT=""
LOCAL_IMAGE=""
REMOTE_IMAGE=""
BASE_IMAGE=""
TARGET_TAG_NORM=""
PREV_TAG_RAW=""
PREV_TAG_NORM=""
HEAD_COMMIT=""
TARGET_COMMIT=""
NEW_IMAGE_ID=""
CONFIG_DIGEST=""
BASE_CID=""

SOABI="cpython-310-aarch64-linux-gnu"

ROOT_RUNNER=()
if [[ "$(id -u)" == "0" ]]; then
  ROOT_RUNNER=()
elif command -v sudo >/dev/null 2>&1; then
  ROOT_RUNNER=(sudo)
fi

declare -a TMP_DIRS=()
declare -a CHANGED_FILES=()
declare -a BUILD_ACTIONS=()
declare -a STAGED_ARTIFACTS=()
declare -A CHANGED_MAP=()
declare -A ACTION_MAP=()
declare -A ARTIFACT_MAP=()
declare -A DELETE_MAP=()

cleanup() {
  local d
  if [[ -n "$BASE_CID" ]]; then
    docker rm -f "$BASE_CID" >/dev/null 2>&1 || true
  fi
  for d in "${TMP_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap cleanup EXIT

log() {
  printf '[release-firmware-nv] %s\n' "$*"
}

fail() {
  printf '[release-firmware-nv] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

run_root() {
  if [[ "${#ROOT_RUNNER[@]}" -eq 0 ]]; then
    "$@"
  else
    "${ROOT_RUNNER[@]}" "$@"
  fi
}

record_action() {
  local action="$1"
  if [[ -z "${ACTION_MAP[$action]:-}" ]]; then
    ACTION_MAP["$action"]=1
    BUILD_ACTIONS+=("$action")
  fi
}

record_artifact() {
  local artifact="$1"
  if [[ -z "${ARTIFACT_MAP[$artifact]:-}" ]]; then
    ARTIFACT_MAP["$artifact"]=1
    STAGED_ARTIFACTS+=("$artifact")
  fi
}

sanitize_tag() {
  printf '%s' "$1" | tr '/:@ ' '____'
}

normalize_tag() {
  local raw="$1"
  if [[ "$raw" =~ (v[0-9].*)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$raw"
  fi
}

ensure_repo_context() {
  [[ -d "$REPO_PATH" ]] || fail "repo path not found: $REPO_PATH"
  [[ -n "$DOCKERFILE_PATH" ]] || DOCKERFILE_PATH="$REPO_PATH/Dockerfile"
  [[ -f "$DOCKERFILE_PATH" ]] || fail "Dockerfile not found: $DOCKERFILE_PATH"

  STATE_ROOT="$REPO_PATH/$STATE_ROOT_REL"
  STAGE_ROOT="$STATE_ROOT/stage"
  STAGE_APP_ROOT="$STAGE_ROOT/rootfs$CONTAINER_ROOT"

  local safe_tag
  safe_tag="$(sanitize_tag "$TARGET_TAG")"
  TAG_STATE_DIR="$STATE_ROOT/$safe_tag"
  METADATA_FILE="$TAG_STATE_DIR/release.env"
  CHANGED_LIST_FILE="$TAG_STATE_DIR/changed_files.txt"
  ACTIONS_LIST_FILE="$TAG_STATE_DIR/build_actions.txt"
  ARTIFACT_LIST_FILE="$TAG_STATE_DIR/staged_artifacts.txt"
}

ensure_clean_worktree() {
  if [[ "$ALLOW_DIRTY" -eq 1 ]]; then
    return 0
  fi
  if [[ -n "$(git -C "$REPO_PATH" status --porcelain)" ]]; then
    fail "worktree is dirty; commit/stash changes or rerun with --allow-dirty"
  fi
}

ensure_tag_state() {
  git -C "$REPO_PATH" rev-parse --verify "$TARGET_TAG^{commit}" >/dev/null 2>&1 || fail "tag not found: $TARGET_TAG"

  HEAD_COMMIT="$(git -C "$REPO_PATH" rev-parse HEAD)"
  TARGET_COMMIT="$(git -C "$REPO_PATH" rev-list -n 1 "$TARGET_TAG")"
  TARGET_TAG_NORM="$(normalize_tag "$TARGET_TAG")"

  if [[ "$ALLOW_TAG_OFF_HEAD" -eq 0 && "$HEAD_COMMIT" != "$TARGET_COMMIT" ]]; then
    fail "tag $TARGET_TAG points to $TARGET_COMMIT but HEAD is $HEAD_COMMIT; checkout the tagged commit or rerun with --allow-tag-off-head"
  fi
}

find_previous_tag() {
  local target_norm="$1"
  local prefix=""
  local found=1
  local tag norm
  local -a lines=()

  if [[ "$target_norm" =~ ^(.*[^0-9])([0-9]+)$ ]]; then
    prefix="${BASH_REMATCH[1]}"
  fi

  while IFS= read -r tag; do
    [[ "$tag" == "$TARGET_TAG" ]] && continue
    norm="$(normalize_tag "$tag")"
    if [[ -n "$prefix" ]]; then
      [[ "$norm" == "$prefix"* ]] || continue
    fi
    lines+=("$norm"$'\t'"$tag")
  done < <(git -C "$REPO_PATH" tag --list)

  if [[ "${#lines[@]}" -eq 0 ]]; then
    return 1
  fi

  while IFS=$'\t' read -r norm tag; do
    if [[ "$norm" == "$target_norm" ]]; then
      break
    fi
    PREV_TAG_RAW="$tag"
    found=0
  done < <(printf '%s\n' "${lines[@]}" | sort -t $'\t' -k1,1V)

  return "$found"
}

resolve_base_image() {
  local candidate
  local -a candidates=()

  if [[ -n "$BASE_IMAGE_OVERRIDE" ]]; then
    BASE_IMAGE="$BASE_IMAGE_OVERRIDE"
    return 0
  fi

  if [[ -n "$PREV_TAG_NORM" ]]; then
    candidates+=("firmware-nv:${PREV_TAG_NORM}-local")
    candidates+=("${REGISTRY_REPO}:${PREV_TAG_NORM}")
  fi
  candidates+=("${REGISTRY_REPO}:latest")

  for candidate in "${candidates[@]}"; do
    if docker image inspect "$candidate" >/dev/null 2>&1; then
      BASE_IMAGE="$candidate"
      return 0
    fi
    if [[ "$candidate" == "$REGISTRY_REPO:"* ]]; then
      if docker pull "$candidate" >/dev/null 2>&1; then
        BASE_IMAGE="$candidate"
        return 0
      fi
    fi
  done

  fail "unable to resolve a usable base image"
}

collect_changed_files() {
  local status path1 path2 key
  CHANGED_FILES=()
  CHANGED_MAP=()
  DELETE_MAP=()

  if [[ -n "$PREV_TAG_RAW" ]]; then
    while IFS=$'\t' read -r status path1 path2; do
      [[ -n "$status" ]] || continue
      case "${status:0:1}" in
        D)
          DELETE_MAP["$path1"]=1
          ;;
        R)
          DELETE_MAP["$path1"]=1
          key="$path2"
          CHANGED_MAP["$key"]=1
          ;;
        *)
          key="$path1"
          CHANGED_MAP["$key"]=1
          ;;
      esac
    done < <(git -C "$REPO_PATH" diff --name-status --find-renames "$PREV_TAG_RAW" "$TARGET_TAG")
  else
    while IFS=$'\t' read -r status path1 path2; do
      [[ -n "$status" ]] || continue
      key="$path1"
      CHANGED_MAP["$key"]=1
    done < <(git -C "$REPO_PATH" diff-tree --no-commit-id --name-status -r "$TARGET_TAG")
  fi

  if [[ "$ALLOW_DIRTY" -eq 1 ]]; then
    while IFS=$'\t' read -r status path1 path2; do
      [[ -n "$status" ]] || continue
      case "${status:0:1}" in
        D)
          DELETE_MAP["$path1"]=1
          ;;
        R)
          DELETE_MAP["$path1"]=1
          key="$path2"
          CHANGED_MAP["$key"]=1
          ;;
        *)
          key="$path1"
          CHANGED_MAP["$key"]=1
          ;;
      esac
    done < <(git -C "$REPO_PATH" diff --name-status --find-renames "$TARGET_TAG")

    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      CHANGED_MAP["$key"]=1
    done < <(git -C "$REPO_PATH" ls-files --others --exclude-standard)
  fi

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    CHANGED_FILES+=("$key")
  done < <(printf '%s\n' "${!CHANGED_MAP[@]}" | sort)
}

reset_stage_dir() {
  rm -rf "$STAGE_ROOT" "$TAG_STATE_DIR"
  mkdir -p "$STAGE_APP_ROOT" "$TAG_STATE_DIR"
  mkdir -p "$STAGE_APP_ROOT/log" "$STAGE_APP_ROOT/camera_calib" "$STAGE_APP_ROOT/tts_cache" "$STAGE_APP_ROOT/config"
}

copy_from_container_rel() {
  local rel="$1"
  local src="$BASE_CID:$CONTAINER_ROOT/$rel"
  local dst="$STAGE_APP_ROOT/$rel"
  mkdir -p "$(dirname "$dst")"
  docker cp "$src" "$dst" >/dev/null 2>&1 || return 1
  return 0
}

copy_tree_from_container_rel() {
  local rel="$1"
  local src="$BASE_CID:$CONTAINER_ROOT/$rel"
  local dst_parent
  dst_parent="$(dirname "$STAGE_APP_ROOT/$rel")"
  mkdir -p "$dst_parent"
  docker cp "$src" "$dst_parent" >/dev/null 2>&1 || return 1
  return 0
}

harvest_base_runtime() {
  local rel

  log "harvesting runtime files from base image: $BASE_IMAGE"
  BASE_CID="$(docker create "$BASE_IMAGE" bash)"

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    if copy_from_container_rel "$rel"; then
      record_artifact "$rel"
    fi
  done < <(
    docker run --rm --entrypoint bash "$BASE_IMAGE" -lc '
set -e
cd '"$CONTAINER_ROOT"'
for fixed in \
  GLZN_CapturePrj/GLZN_CAPTURE_APP \
  oss_uploader/build/oss_uploader \
  displayd/build/glzn-displayd \
  config/wifi_interfaces.conf; do
  [ -f "$fixed" ] && printf "%s\n" "$fixed"
done
find scripts -maxdepth 2 -type f \( -name "*.sh" -o -name "*.so" -o -name "__init__.py" -o -name "auto_capture_pico_main.py" \) | sort
if [ -d wifi_provisioning ]; then
  find wifi_provisioning -type f ! -path "*/__pycache__/*" ! -name "setup.py" | sort
fi
find vendor/human_case_sdk -maxdepth 3 -type f \( -name "*.so" -o -name "__init__.py" -o -name "main.py" \) | sort
'
  )

  if docker run --rm --entrypoint bash "$BASE_IMAGE" -lc "test -d '$CONTAINER_ROOT/displayd/qml'" >/dev/null 2>&1; then
    copy_tree_from_container_rel "displayd/qml" || true
    record_artifact "displayd/qml"
  fi

  if docker run --rm --entrypoint bash "$BASE_IMAGE" -lc "test -d '$CONTAINER_ROOT/wifi_provisioning'" >/dev/null 2>&1; then
    copy_tree_from_container_rel "wifi_provisioning" || true
    find "$STAGE_APP_ROOT/wifi_provisioning" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
    rm -f "$STAGE_APP_ROOT/wifi_provisioning/setup.py"
    record_artifact "wifi_provisioning"
  fi
}

remove_runtime_for_deleted_path() {
  local rel="$1"
  local dir base name

  if [[ "$rel" =~ ^scripts/tools/[^/]+\.py$ ]]; then
    base="$(basename "$rel")"
    name="${base%.py}"
    find "$STAGE_APP_ROOT/$(dirname "$rel")" -maxdepth 1 -name "${name}.${SOABI}.so" -delete 2>/dev/null || true
    return 0
  fi

  if [[ "$rel" =~ ^scripts/[^/]+\.py$ ]]; then
    base="$(basename "$rel")"
    name="${base%.py}"
    if [[ "$base" == "auto_capture_pico_main.py" || "$base" == "__init__.py" ]]; then
      rm -f "$STAGE_APP_ROOT/$rel"
    else
      find "$STAGE_APP_ROOT/$(dirname "$rel")" -maxdepth 1 -name "${name}.${SOABI}.so" -delete 2>/dev/null || true
    fi
    return 0
  fi

  if [[ "$rel" =~ ^wifi_provisioning/[^/]+\.py$ ]]; then
    base="$(basename "$rel")"
    name="${base%.py}"
    if [[ "$base" == "unified_server_main.py" || "$base" == "__init__.py" ]]; then
      rm -f "$STAGE_APP_ROOT/$rel"
    else
      find "$STAGE_APP_ROOT/$(dirname "$rel")" -maxdepth 1 -name "${name}.cpython-*.so" -delete 2>/dev/null || true
    fi
    return 0
  fi

  if [[ "$rel" =~ ^vendor/human_case_sdk/clients/[^/]+\.py$ ]]; then
    base="$(basename "$rel")"
    name="${base%.py}"
    if [[ "$base" == "__init__.py" ]]; then
      rm -f "$STAGE_APP_ROOT/$rel"
    else
      find "$STAGE_APP_ROOT/$(dirname "$rel")" -maxdepth 1 -name "${name}.${SOABI}.so" -delete 2>/dev/null || true
    fi
    return 0
  fi

  if [[ "$rel" =~ ^vendor/human_case_sdk/[^/]+\.py$ ]]; then
    base="$(basename "$rel")"
    name="${base%.py}"
    if [[ "$base" == "__init__.py" || "$base" == "main.py" ]]; then
      rm -f "$STAGE_APP_ROOT/$rel"
    else
      find "$STAGE_APP_ROOT/$(dirname "$rel")" -maxdepth 1 -name "${name}.${SOABI}.so" -delete 2>/dev/null || true
    fi
    return 0
  fi

  case "$rel" in
    GLZN_CapturePrj/*)
      rm -f "$STAGE_APP_ROOT/GLZN_CapturePrj/GLZN_CAPTURE_APP"
      ;;
    oss_uploader/*)
      rm -f "$STAGE_APP_ROOT/oss_uploader/build/oss_uploader"
      ;;
    scripts/*.sh)
      rm -f "$STAGE_APP_ROOT/$rel"
      ;;
    wifi_provisioning/*)
      rm -rf "$STAGE_APP_ROOT/wifi_provisioning"
      ;;
    displayd/*)
      rm -rf "$STAGE_APP_ROOT/displayd"
      ;;
    config/wifi_interfaces.conf)
      rm -f "$STAGE_APP_ROOT/config/wifi_interfaces.conf"
      ;;
  esac
}

ensure_cython() {
  if command -v cythonize >/dev/null 2>&1; then
    return 0
  fi
  if python3 -c 'import Cython' >/dev/null 2>&1; then
    return 0
  fi
  fail "Cython not found on host; install it in the build environment first"
}

compile_python_module_to_stage() {
  local rel="$1"
  local abs="$REPO_PATH/$rel"
  local module_dir module_base module_name tmp_dir so_file stage_dir

  [[ -f "$abs" ]] || fail "python source not found: $abs"
  ensure_cython

  module_dir="$(dirname "$rel")"
  module_base="$(basename "$rel")"
  module_name="${module_base%.py}"
  tmp_dir="$(mktemp -d /tmp/release_nv_cython_XXXXXX)"
  TMP_DIRS+=("$tmp_dir")
  cp "$abs" "$tmp_dir/$module_base"

  log "cythonizing $rel"
  (
    cd "$tmp_dir"
    cythonize -3 -i "$module_base" >/dev/null
  )

  so_file="$(find "$tmp_dir" -maxdepth 1 -type f -name "${module_name}.cpython-*.so" | head -n1)"
  [[ -n "$so_file" ]] || fail "compiled module not found for $rel"

  stage_dir="$STAGE_APP_ROOT/$module_dir"
  mkdir -p "$stage_dir"
  find "$stage_dir" -maxdepth 1 -name "${module_name}.cpython-*.so" -delete 2>/dev/null || true
  cp "$so_file" "$stage_dir/"
  record_action "cythonize $rel"
  record_artifact "$module_dir/$(basename "$so_file")"
}

copy_repo_file_to_stage() {
  local rel="$1"
  local abs="$REPO_PATH/$rel"
  local dst="$STAGE_APP_ROOT/$rel"
  [[ -f "$abs" ]] || fail "source file not found: $abs"
  mkdir -p "$(dirname "$dst")"
  cp "$abs" "$dst"
  record_artifact "$rel"
}

build_capture_app() {
  log "building GLZN_CAPTURE_APP"
  make -C "$REPO_PATH/GLZN_CapturePrj/BaseAndHal" BaseAndHalLib.a -j"$(nproc)"
  make -C "$REPO_PATH/GLZN_CapturePrj/AppLayer" -j"$(nproc)"
  copy_repo_file_to_stage "GLZN_CapturePrj/GLZN_CAPTURE_APP"
  record_action "build GLZN_CAPTURE_APP"
}

build_oss_uploader() {
  log "building oss_uploader"
  make -C "$REPO_PATH/oss_uploader" -j"$(nproc)"
  copy_repo_file_to_stage "oss_uploader/build/oss_uploader"
  record_action "build oss_uploader"
}

build_displayd() {
  log "building displayd"
  bash "$REPO_PATH/scripts/build_displayd.sh"
  copy_repo_file_to_stage "displayd/build/glzn-displayd"
  if [[ -d "$REPO_PATH/displayd/qml" ]]; then
    mkdir -p "$STAGE_APP_ROOT/displayd"
    rm -rf "$STAGE_APP_ROOT/displayd/qml"
    cp -r "$REPO_PATH/displayd/qml" "$STAGE_APP_ROOT/displayd/qml"
    record_artifact "displayd/qml"
  fi
  record_action "build displayd"
}

rebuild_all_scripts_modules() {
  local rel
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    compile_python_module_to_stage "$rel"
  done < <(find "$REPO_PATH/scripts" -maxdepth 1 -type f -name '*.py' ! -name '__init__.py' ! -name 'auto_capture_pico_main.py' ! -name 'setup.py' -printf 'scripts/%f\n' | sort)
}

rebuild_vendor_modules() {
  local rel
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    compile_python_module_to_stage "$rel"
  done < <(find "$REPO_PATH/vendor/human_case_sdk" -maxdepth 1 -type f -name '*.py' ! -name '__init__.py' ! -name 'main.py' ! -name 'setup.py' -printf 'vendor/human_case_sdk/%f\n' | sort)

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    compile_python_module_to_stage "$rel"
  done < <(find "$REPO_PATH/vendor/human_case_sdk/clients" -maxdepth 1 -type f -name '*.py' ! -name '__init__.py' ! -name 'setup.py' -printf 'vendor/human_case_sdk/clients/%f\n' | sort)
}

rebuild_wifi_provisioning_modules() {
  local rel
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    compile_python_module_to_stage "$rel"
  done < <(find "$REPO_PATH/wifi_provisioning" -maxdepth 1 -type f -name '*.py' ! -name '__init__.py' ! -name 'unified_server_main.py' ! -name 'setup.py' -printf 'wifi_provisioning/%f\n' | sort)
}

apply_deleted_paths() {
  local rel
  for rel in "${!DELETE_MAP[@]}"; do
    remove_runtime_for_deleted_path "$rel"
  done
}

apply_changed_paths() {
  local rel base name
  local need_capture_build=0
  local need_oss_build=0
  local need_displayd_build=0
  local need_full_scripts_rebuild=0
  local need_full_wifi_provisioning_rebuild=0
  local need_full_vendor_rebuild=0
  local need_full_wifi_tree_sync=0
  local need_wifi_module_recompile=0

  for rel in "${CHANGED_FILES[@]}"; do
    if [[ "$rel" =~ ^scripts/tools/[^/]+\.py$ ]]; then
      compile_python_module_to_stage "$rel"
      continue
    fi

    if [[ "$rel" =~ ^scripts/[^/]+\.py$ ]]; then
      case "$rel" in
        scripts/auto_capture_pico_main.py|scripts/__init__.py)
          copy_repo_file_to_stage "$rel"
          record_action "sync $rel"
          ;;
        scripts/setup.py)
          need_full_scripts_rebuild=1
          ;;
        *)
          compile_python_module_to_stage "$rel"
          ;;
      esac
      continue
    fi

    if [[ "$rel" =~ ^wifi_provisioning/[^/]+\.py$ ]]; then
      case "$rel" in
        wifi_provisioning/unified_server_main.py)
          copy_repo_file_to_stage "$rel"
          record_action "sync $rel"
          ;;
        wifi_provisioning/setup.py)
          need_full_wifi_provisioning_rebuild=1
          need_wifi_module_recompile=1
          ;;
        *)
          compile_python_module_to_stage "$rel"
          need_wifi_module_recompile=1
          ;;
      esac
      need_full_wifi_tree_sync=1
      continue
    fi

    if [[ "$rel" =~ ^vendor/human_case_sdk/clients/[^/]+\.py$ ]]; then
      case "$rel" in
        vendor/human_case_sdk/clients/__init__.py)
          copy_repo_file_to_stage "$rel"
          record_action "sync $rel"
          ;;
        vendor/human_case_sdk/clients/setup.py)
          need_full_vendor_rebuild=1
          ;;
        *)
          compile_python_module_to_stage "$rel"
          ;;
      esac
      continue
    fi

    if [[ "$rel" =~ ^vendor/human_case_sdk/[^/]+\.py$ ]]; then
      case "$rel" in
        vendor/human_case_sdk/__init__.py|vendor/human_case_sdk/main.py)
          copy_repo_file_to_stage "$rel"
          record_action "sync $rel"
          ;;
        vendor/human_case_sdk/setup.py)
          need_full_vendor_rebuild=1
          ;;
        *)
          compile_python_module_to_stage "$rel"
          ;;
      esac
      continue
    fi

    case "$rel" in
      GLZN_CapturePrj/*)
        need_capture_build=1
        ;;
      oss_uploader/*)
        need_oss_build=1
        ;;
      displayd/*|scripts/build_displayd.sh)
        need_displayd_build=1
        ;;
      scripts/*.sh)
        copy_repo_file_to_stage "$rel"
        record_action "sync $rel"
        ;;
      config/wifi_interfaces.conf)
        copy_repo_file_to_stage "$rel"
        record_action "sync $rel"
        ;;
      wifi_provisioning/*.sh|wifi_provisioning/*.conf|wifi_provisioning/unified_server_main.py|wifi_provisioning/ble_wifi_provision_launcher.py)
        copy_repo_file_to_stage "$rel"
        record_action "sync $rel"
        need_full_wifi_tree_sync=1
        ;;
      wifi_provisioning/*)
        need_full_wifi_tree_sync=1
        ;;
    esac
  done

  if [[ "$need_full_wifi_tree_sync" -eq 1 ]]; then
    rm -rf "$STAGE_APP_ROOT/wifi_provisioning"
    mkdir -p "$STAGE_APP_ROOT"
    cp -r "$REPO_PATH/wifi_provisioning" "$STAGE_APP_ROOT/wifi_provisioning"
    rm -f "$STAGE_APP_ROOT/wifi_provisioning/setup.py"
    find "$STAGE_APP_ROOT/wifi_provisioning" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
    record_action "sync wifi_provisioning tree"
    record_artifact "wifi_provisioning"
  fi

  if [[ "$need_capture_build" -eq 1 ]]; then
    build_capture_app
  fi
  if [[ "$need_oss_build" -eq 1 ]]; then
    build_oss_uploader
  fi
  if [[ "$need_full_scripts_rebuild" -eq 1 ]]; then
    rebuild_all_scripts_modules
    record_action "rebuild all scripts/*.py modules"
  fi
  if [[ "$need_full_wifi_provisioning_rebuild" -eq 1 ]]; then
    rebuild_wifi_provisioning_modules
    record_action "rebuild wifi_provisioning modules"
  elif [[ "$need_wifi_module_recompile" -eq 1 ]]; then
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      if [[ "$rel" =~ ^wifi_provisioning/[^/]+\.py$ && "$rel" != "wifi_provisioning/unified_server_main.py" && "$rel" != "wifi_provisioning/setup.py" ]]; then
        compile_python_module_to_stage "$rel"
      fi
    done < <(printf '%s\n' "${CHANGED_FILES[@]}" | sort -u)
  fi
  if [[ "$need_full_vendor_rebuild" -eq 1 ]]; then
    rebuild_vendor_modules
    record_action "rebuild vendor/human_case_sdk modules"
  fi
  if [[ "$need_displayd_build" -eq 1 ]]; then
    build_displayd
  fi
}

write_list_file() {
  local file="$1"
  shift
  : > "$file"
  if [[ "$#" -eq 0 ]]; then
    return 0
  fi
  printf '%s\n' "$@" > "$file"
}

write_metadata() {
  LOCAL_IMAGE="firmware-nv:${TARGET_TAG_NORM}-local"
  REMOTE_IMAGE="${REGISTRY_REPO}:${TARGET_TAG_NORM}"
  NEW_IMAGE_ID="$(docker image inspect "$LOCAL_IMAGE" --format '{{.Id}}')"

  mkdir -p "$TAG_STATE_DIR"
  write_list_file "$CHANGED_LIST_FILE" "${CHANGED_FILES[@]}"
  write_list_file "$ACTIONS_LIST_FILE" "${BUILD_ACTIONS[@]}"
  write_list_file "$ARTIFACT_LIST_FILE" "${STAGED_ARTIFACTS[@]}"

  cat > "$METADATA_FILE" <<META
TARGET_TAG=$(printf '%q' "$TARGET_TAG")
TARGET_TAG_NORM=$(printf '%q' "$TARGET_TAG_NORM")
PREV_TAG_RAW=$(printf '%q' "$PREV_TAG_RAW")
PREV_TAG_NORM=$(printf '%q' "$PREV_TAG_NORM")
BASE_IMAGE=$(printf '%q' "$BASE_IMAGE")
LOCAL_IMAGE=$(printf '%q' "$LOCAL_IMAGE")
REMOTE_IMAGE=$(printf '%q' "$REMOTE_IMAGE")
HEAD_COMMIT=$(printf '%q' "$HEAD_COMMIT")
REPO_PATH=$(printf '%q' "$REPO_PATH")
CONTAINER_NAME=$(printf '%q' "$CONTAINER_NAME")
CONTAINER_ROOT=$(printf '%q' "$CONTAINER_ROOT")
SERVICE_NAME=$(printf '%q' "$SERVICE_NAME")
REGISTRY_REPO=$(printf '%q' "$REGISTRY_REPO")
STATE_ROOT=$(printf '%q' "$STATE_ROOT")
TAG_STATE_DIR=$(printf '%q' "$TAG_STATE_DIR")
METADATA_FILE=$(printf '%q' "$METADATA_FILE")
CHANGED_LIST_FILE=$(printf '%q' "$CHANGED_LIST_FILE")
ACTIONS_LIST_FILE=$(printf '%q' "$ACTIONS_LIST_FILE")
ARTIFACT_LIST_FILE=$(printf '%q' "$ARTIFACT_LIST_FILE")
STAGE_ROOT=$(printf '%q' "$STAGE_ROOT")
DOCKERFILE_PATH=$(printf '%q' "$DOCKERFILE_PATH")
META
}

load_metadata() {
  [[ -f "$METADATA_FILE" ]] || fail "prepare metadata not found: $METADATA_FILE"
  # shellcheck disable=SC1090
  source "$METADATA_FILE"
}

print_prepare_summary() {
  echo
  printf 'prepare_summary\n'
  printf '  phase: %s\n' "$PHASE"
  printf '  git_head: %s\n' "${HEAD_COMMIT:0:12}"
  printf '  target_tag: %s\n' "$TARGET_TAG"
  printf '  target_tag_norm: %s\n' "$TARGET_TAG_NORM"
  printf '  previous_tag: %s\n' "${PREV_TAG_RAW:-N/A}"
  printf '  previous_tag_norm: %s\n' "${PREV_TAG_NORM:-N/A}"
  printf '  base_image: %s\n' "$BASE_IMAGE"
  printf '  local_image: %s\n' "$LOCAL_IMAGE"
  printf '  new_image_id: %s\n' "$NEW_IMAGE_ID"
  printf '  stage_root: %s\n' "$STAGE_ROOT/rootfs"

  printf '  changed_files_count: %s\n' "${#CHANGED_FILES[@]}"
  if [[ -f "$CHANGED_LIST_FILE" && -s "$CHANGED_LIST_FILE" ]]; then
    printf '  changed_files_list: %s\n' "$CHANGED_LIST_FILE"
  fi
  printf '  actions_count: %s\n' "${#BUILD_ACTIONS[@]}"
  if [[ -f "$ACTIONS_LIST_FILE" && -s "$ACTIONS_LIST_FILE" ]]; then
    printf '  actions_list: %s\n' "$ACTIONS_LIST_FILE"
  fi
  printf '  staged_artifacts_count: %s\n' "${#STAGED_ARTIFACTS[@]}"
  if [[ -f "$ARTIFACT_LIST_FILE" && -s "$ARTIFACT_LIST_FILE" ]]; then
    printf '  staged_artifacts_list: %s\n' "$ARTIFACT_LIST_FILE"
  fi
}

prepare_phase() {
  ensure_repo_context
  ensure_clean_worktree
  ensure_tag_state

  PREV_TAG_RAW=""
  PREV_TAG_NORM=""
  if find_previous_tag "$TARGET_TAG_NORM"; then
    PREV_TAG_NORM="$(normalize_tag "$PREV_TAG_RAW")"
  fi

  resolve_base_image
  collect_changed_files
  reset_stage_dir
  harvest_base_runtime
  apply_deleted_paths
  apply_changed_paths

  LOCAL_IMAGE="firmware-nv:${TARGET_TAG_NORM}-local"
  log "building local image: $LOCAL_IMAGE"
  docker build \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg RELEASE_TAG="$TARGET_TAG_NORM" \
    --build-arg RELEASE_GIT_HEAD="$HEAD_COMMIT" \
    -f "$DOCKERFILE_PATH" \
    -t "$LOCAL_IMAGE" \
    "$REPO_PATH"

  write_metadata
  print_prepare_summary

  echo
  printf 'next_step\n'
  printf '  regression: %s regression --tag %s\n' "$0" "$TARGET_TAG"
  printf '  push: %s push --tag %s\n' "$0" "$TARGET_TAG"
}

recreate_container_from_local_image() {
  local image="$1"
  local -a extra_env=()
  local -a extra_mounts=()

  if [[ -S /tmp/.X11-unix/X0 ]]; then
    extra_env+=(-e DISPLAY=:0)
    extra_mounts+=(-v /tmp/.X11-unix:/tmp/.X11-unix)
  fi

  if [[ -r /run/user/1000/gdm/Xauthority ]]; then
    extra_mounts+=(-v /run/user/1000/gdm/Xauthority:/root/.Xauthority-gdm:ro)
  fi

  if [[ -S /run/dbus/system_bus_socket ]]; then
    extra_mounts+=(-v /run/dbus/system_bus_socket:/run/dbus/system_bus_socket)
  fi

  if [[ -S /var/run/dbus/system_bus_socket ]]; then
    extra_mounts+=(-v /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket)
  fi

  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker run --runtime nvidia -d \
    --name "$CONTAINER_NAME" \
    --network=host \
    --privileged \
    --ipc=host \
    -v /dev:/dev \
    -v /sys/kernel/debug:/sys/kernel/debug:ro \
    -v /data:/data \
    -v /data/glzn/config:"$CONTAINER_ROOT"/config \
    -v /data/glzn/log:"$CONTAINER_ROOT"/log \
    -v /data/glzn/camera_calib:"$CONTAINER_ROOT"/camera_calib \
    "${extra_env[@]}" \
    "${extra_mounts[@]}" \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=compute,utility,video,graphics \
    -w "$CONTAINER_ROOT" \
    "$image" \
    tail -f /dev/null >/dev/null
}

wait_for_service_active() {
  local attempt
  for attempt in $(seq 1 20); do
    if run_root systemctl is-active --quiet "$SERVICE_NAME"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_container_processes() {
  local attempt
  for attempt in $(seq 1 30); do
    if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME" && \
       docker exec "$CONTAINER_NAME" pgrep -f GLZN_CAPTURE_APP >/dev/null 2>&1 && \
       docker exec "$CONTAINER_NAME" pgrep -f auto_capture_pico_main.py >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_websocket_ready() {
  local attempt
  for attempt in $(seq 1 30); do
    if docker exec -i "$CONTAINER_NAME" python3 - <<'PY' >/dev/null 2>&1
import socket
import sys

s = socket.socket()
s.settimeout(1.0)
try:
    s.connect(("127.0.0.1", 8765))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
    then
      return 0
    fi
    sleep 1
  done
  return 1
}

validate_capture_output() {
  local session_dir="$1"
  docker exec "$CONTAINER_NAME" bash -lc '
set -e
[ -n "$1" ] || { echo "missing session dir" >&2; exit 1; }
latest="$1"
[ -d "$latest" ] || { echo "capture session missing: $latest" >&2; exit 1; }
shopt -s nullglob
mp4s=("$latest"/*.mp4)
if [ ${#mp4s[@]} -eq 0 ]; then
  echo "no mp4 found in $latest" >&2
  ls -la "$latest" >&2 || true
  exit 1
fi
printf "latest_session=%s\n" "$latest"
for f in "${mp4s[@]}"; do
  stat --printf="%n %s bytes\n" "$f"
done
if [ -f "$latest/metadata_rk.json" ]; then
  printf "metadata=%s\n" "$latest/metadata_rk.json"
fi
' _ "$session_dir"
}

regression_phase() {
  local before_list after_list new_session
  ensure_repo_context
  load_metadata

  log "stopping host service before container refresh"
  run_root systemctl stop "$SERVICE_NAME" || true

  log "recreating container $CONTAINER_NAME from $LOCAL_IMAGE"
  recreate_container_from_local_image "$LOCAL_IMAGE"

  log "starting host service $SERVICE_NAME"
  run_root systemctl start "$SERVICE_NAME"
  wait_for_service_active || fail "service failed to become active: $SERVICE_NAME"
  wait_for_container_processes || fail "container processes did not become ready"
  wait_for_websocket_ready || fail "websocket service did not become ready on 127.0.0.1:8765"

  before_list="$(docker exec "$CONTAINER_NAME" bash -lc 'find /data/capture -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort' || true)"

  log "running one capture via inline websocket client"
  docker exec -i "$CONTAINER_NAME" python3 - <<'PY'
import asyncio
import json
import time

import websockets


async def recv_until_quiet(ws, label, quiet=0.8, total=5.0):
    start = time.time()
    last = start
    msgs = []
    while time.time() - start < total:
        timeout = min(quiet, total - (time.time() - start))
        try:
            msg = await asyncio.wait_for(ws.recv(), timeout=timeout)
            msgs.append(msg)
            last = time.time()
        except asyncio.TimeoutError:
            if time.time() - last >= quiet:
                break
    print(f"## {label} messages={len(msgs)}", flush=True)
    for msg in msgs:
        print(msg, flush=True)
    return msgs


async def send_and_wait(ws, payload, label, quiet=1.0, total=6.0, settle=0.5):
    payload = dict(payload)
    payload["timestamp"] = int(time.time() * 1000)
    print("SEND", json.dumps(payload, ensure_ascii=False), flush=True)
    await ws.send(json.dumps(payload, ensure_ascii=False))
    msgs = await recv_until_quiet(ws, label, quiet=quiet, total=total)
    if settle > 0:
        await asyncio.sleep(settle)
    return msgs


async def main():
    uri = "ws://127.0.0.1:8765"
    last_err = None
    for _ in range(20):
        try:
            ws = await websockets.connect(
                uri,
                ping_interval=None,
                ping_timeout=None,
                open_timeout=5,
            )
            break
        except Exception as exc:
            last_err = exc
            await asyncio.sleep(1)
    else:
        raise RuntimeError(f"failed to connect to {uri}: {last_err}")

    async with ws:
        await asyncio.sleep(1.0)
        await send_and_wait(
            ws,
            {
                "action": "login",
                "login_info": {"name": "release.skill", "auth": "Bearer release_test"},
            },
            "login",
            quiet=1.0,
            total=6.0,
            settle=1.0,
        )
        await send_and_wait(
            ws,
            {
                "action": "pull_job",
                "project_uuid": "release-skill-project",
                "data_id": "release-skill-data",
            },
            "pull_job",
            quiet=1.0,
            total=6.0,
            settle=1.0,
        )
        await send_and_wait(
            ws,
            {
                "action": "start_record",
            },
            "start_record",
            quiet=1.0,
            total=6.0,
            settle=0.5,
        )

        await asyncio.sleep(6)

        await send_and_wait(
            ws,
            {
                "action": "stop_record",
            },
            "stop_record",
            quiet=1.0,
            total=10.0,
            settle=0.0,
        )


asyncio.run(main())
PY

  after_list="$(docker exec "$CONTAINER_NAME" bash -lc 'find /data/capture -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort' || true)"
  new_session="$(comm -13 <(printf '%s\n' "$before_list") <(printf '%s\n' "$after_list") | tail -n1)"
  [[ -n "$new_session" ]] || fail "no new capture session created under /data/capture"

  log "validating capture output"
  validate_capture_output "/data/capture/$new_session"

  echo
  printf 'regression_summary\n'
  printf '  service: %s\n' "$SERVICE_NAME"
  printf '  container: %s\n' "$CONTAINER_NAME"
  printf '  local_image: %s\n' "$LOCAL_IMAGE"
  printf '  result: ok\n'
}

delete_remote_tag() {
  local registry_host repo_path challenge_file auth_header realm service scope token_json token head_file head_code digest del_code

  if [[ -z "$HARBOR_USER" || -z "$HARBOR_PASSWORD" ]]; then
    fail "--delete-existing-tag requires Harbor credentials"
  fi

  registry_host="${REGISTRY_REPO%%/*}"
  repo_path="${REGISTRY_REPO#*/}"
  [[ "$registry_host" != "$REGISTRY_REPO" && -n "$repo_path" ]] || fail "unexpected registry format: $REGISTRY_REPO"

  challenge_file="$(mktemp)"
  curl -sS -D "$challenge_file" -o /dev/null "https://${registry_host}/v2/" >/dev/null || true
  auth_header="$(awk 'tolower($1)=="www-authenticate:" {sub(/^[^:]+:[[:space:]]*/, ""); gsub("\r", ""); print; exit}' "$challenge_file")"
  rm -f "$challenge_file"
  [[ -n "$auth_header" ]] || fail "unable to fetch Harbor auth challenge"

  realm="$(printf '%s' "$auth_header" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')"
  service="$(printf '%s' "$auth_header" | sed -n 's/.*service="\([^"]*\)".*/\1/p')"
  scope="repository:${repo_path}:pull,push,delete"
  [[ -n "$realm" && -n "$service" ]] || fail "invalid Harbor auth challenge"

  token_json="$(curl -sS -u "${HARBOR_USER}:${HARBOR_PASSWORD}" "${realm}?service=${service}&scope=${scope}")"
  token="$(printf '%s' "$token_json" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("token") or data.get("access_token") or "")' 2>/dev/null || true)"
  [[ -n "$token" ]] || fail "unable to get Harbor token"

  head_file="$(mktemp)"
  head_code="$(curl -sS -o /dev/null -D "$head_file" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "https://${registry_host}/v2/${repo_path}/manifests/${TARGET_TAG_NORM}" || true)"

  if [[ "$head_code" == "404" ]]; then
    rm -f "$head_file"
    log "remote tag not found, skip delete"
    return 0
  fi
  [[ "$head_code" == "200" ]] || fail "failed querying manifest digest for ${TARGET_TAG_NORM} (${head_code})"

  digest="$(awk -F': ' 'tolower($1)=="docker-content-digest" {gsub("\r","",$2); print $2; exit}' "$head_file")"
  rm -f "$head_file"
  [[ -n "$digest" ]] || fail "missing docker-content-digest for ${TARGET_TAG_NORM}"

  del_code="$(curl -sS -o /tmp/release_nv_delete_manifest_body.txt -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer ${token}" \
    "https://${registry_host}/v2/${repo_path}/manifests/${digest}" || true)"

  case "$del_code" in
    200|202|204)
      log "deleted remote tag ${TARGET_TAG_NORM} (${digest})"
      ;;
    404)
      log "remote manifest already absent for ${TARGET_TAG_NORM}"
      ;;
    *)
      fail "delete remote tag failed (${del_code})"
      ;;
  esac
}

push_phase() {
  ensure_repo_context
  load_metadata

  docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1 || fail "local image not found: $LOCAL_IMAGE"
  docker tag "$LOCAL_IMAGE" "$REMOTE_IMAGE"

  if [[ "$DELETE_EXISTING_TAG" -eq 1 ]]; then
    delete_remote_tag
  fi

  log "pushing $REMOTE_IMAGE"
  docker push "$REMOTE_IMAGE"
  CONFIG_DIGEST="$(docker manifest inspect "$REMOTE_IMAGE" | awk -F'"' '/"config"/{in_cfg=1} in_cfg && /"digest"/ {print $4; exit}')"

  echo
  printf 'push_summary\n'
  printf '  git_head: %s\n' "$HEAD_COMMIT"
  printf '  target_tag: %s\n' "$TARGET_TAG"
  printf '  remote_image: %s\n' "$REMOTE_IMAGE"
  printf '  config_digest: %s\n' "${CONFIG_DIGEST:-N/A}"
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    prepare|regression|push)
      PHASE="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TARGET_TAG="${2:-}"
      shift 2
      ;;
    --repo)
      REPO_PATH="${2:-}"
      shift 2
      ;;
    --registry)
      REGISTRY_REPO="${2:-}"
      shift 2
      ;;
    --dockerfile)
      DOCKERFILE_PATH="${2:-}"
      shift 2
      ;;
    --container)
      CONTAINER_NAME="${2:-}"
      shift 2
      ;;
    --container-root)
      CONTAINER_ROOT="${2:-}"
      shift 2
      ;;
    --service)
      SERVICE_NAME="${2:-}"
      shift 2
      ;;
    --base-image)
      BASE_IMAGE_OVERRIDE="${2:-}"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --allow-tag-off-head)
      ALLOW_TAG_OFF_HEAD=1
      shift
      ;;
    --delete-existing-tag)
      DELETE_EXISTING_TAG=1
      shift
      ;;
    --harbor-user)
      HARBOR_USER="${2:-}"
      shift 2
      ;;
    --harbor-password)
      HARBOR_PASSWORD="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$TARGET_TAG" ]] || fail "--tag is required"

need_cmd git
need_cmd docker
need_cmd python3

case "$PHASE" in
  prepare)
    prepare_phase
    ;;
  regression)
    ensure_repo_context
    regression_phase
    ;;
  push)
    ensure_repo_context
    push_phase
    ;;
  *)
    fail "unsupported phase: $PHASE"
    ;;
esac
