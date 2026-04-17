#!/bin/bash
# =============================================================================
# build_npu_aar.sh
#
# Builds MediaPipe Tasks Vision AAR (arm64-v8a) with Arm NN / Ethos-N78 NPU
# delegate support.
#
# Prerequisites installed by this script if missing:
#   - Android SDK (command-line tools, platform 36, build-tools 35)
#   - Android NDK r28b
#   - Bazel 6.x (via bazelisk)
#
# Usage:
#   cd /mnt/disk1/telechips/mediapipe
#   bash build_npu_aar.sh [--sdk-dir DIR] [--ndk-dir DIR] [--skip-sdk-install]
#
# Output:
#   bazel-bin/mediapipe/tasks/java/com/google/mediapipe/tasks/vision/tasks_vision.aar
#   bazel-bin/mediapipe/tasks/java/com/google/mediapipe/tasks/core/tasks_core.aar
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration — override via environment variables or CLI flags             #
# --------------------------------------------------------------------------- #
ANDROID_SDK_DIR="${ANDROID_HOME:-$HOME/Android/Sdk}"
# NDK installed via Android Studio/sdkmanager under $ANDROID_HOME/ndk/<version>
# Falls back to ANDROID_NDK_HOME env var if set, otherwise auto-detects.
_NDK_AUTO=$(ls -1d "${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/"*/ 2>/dev/null | sort -V | tail -1)
ANDROID_NDK_DIR="${ANDROID_NDK_HOME:-${_NDK_AUTO%/}}"
SDK_API_LEVEL="36"
BUILD_TOOLS_VERSION="35.0.0"
MEDIAPIPE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bazel output root — defaults to ~/.cache/bazel (ext4, supports Unix sockets/symlinks)
# Override with --bazel-cache or BAZEL_OUTPUT_ROOT env var
BAZEL_OUTPUT_ROOT="${BAZEL_OUTPUT_ROOT:-$HOME/.cache/bazel}"

# Auto-skip install if SDK platforms directory already exists
if [[ -d "${ANDROID_HOME:-$HOME/Android/Sdk}/platforms" ]]; then
  SKIP_SDK_INSTALL=true
else
  SKIP_SDK_INSTALL=false
fi

# Arm NN prebuilt libraries
ARMNN_BUILD_DIR="/mnt/disk1/telechips/armnn/build_aarch64"
ARMNN_SRC_DIR="/mnt/disk1/telechips/armnn"
ETHOSN_INSTALL_DIR="/mnt/disk1/telechips/ethos-n-driver-stack/driver/installDir"

# --------------------------------------------------------------------------- #
# Parse CLI args                                                               #
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sdk-dir)   ANDROID_SDK_DIR="$2"; shift 2 ;;
    --ndk-dir)   ANDROID_NDK_DIR="$2"; shift 2 ;;
    --bazel-cache) BAZEL_OUTPUT_ROOT="$2"; shift 2 ;;
    --skip-sdk-install) SKIP_SDK_INSTALL=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "============================================================"
echo "  MediaPipe NPU AAR Build"
echo "  SDK  : $ANDROID_SDK_DIR"
echo "  NDK  : $ANDROID_NDK_DIR"
echo "  Root : $MEDIAPIPE_ROOT"
echo "  Bazel: $BAZEL_OUTPUT_ROOT"
echo "============================================================"

# --------------------------------------------------------------------------- #
# Step 1: Install Android SDK + NDK if not already present                   #
# --------------------------------------------------------------------------- #
if [[ "$SKIP_SDK_INSTALL" == "false" ]]; then
  if [[ ! -d "$ANDROID_SDK_DIR/platforms/android-${SDK_API_LEVEL}" ]]; then
    echo ""
    echo ">>> [1/6] Installing Android SDK to $ANDROID_SDK_DIR ..."
    mkdir -p "$ANDROID_SDK_DIR"

    # Download command-line tools
    CMDLINE_TOOLS_ZIP="/tmp/cmdline-tools.zip"
    if [[ ! -f "$CMDLINE_TOOLS_ZIP" ]]; then
      curl -Lo "$CMDLINE_TOOLS_ZIP" \
        "https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"
    fi
    unzip -qo "$CMDLINE_TOOLS_ZIP" -d /tmp/android_cmdline/

    yes | /tmp/android_cmdline/cmdline-tools/bin/sdkmanager \
      --licenses --sdk_root="$ANDROID_SDK_DIR" || true

    /tmp/android_cmdline/cmdline-tools/bin/sdkmanager \
      --sdk_root="$ANDROID_SDK_DIR" \
      "platforms;android-${SDK_API_LEVEL}" \
      "build-tools;${BUILD_TOOLS_VERSION}" \
      "platform-tools" \
      "extras;android;m2repository"
    rm -rf /tmp/android_cmdline/ "$CMDLINE_TOOLS_ZIP"
    echo "    SDK installed."
  else
    echo ">>> [1/6] Android SDK already present, skipping install."
  fi

  if [[ ! -d "$ANDROID_NDK_DIR" ]]; then
    echo ""
    echo ">>> Installing Android NDK ${NDK_VERSION} to $ANDROID_NDK_DIR ..."
    NDK_ZIP="/tmp/android-ndk.zip"
    if [[ ! -f "$NDK_ZIP" ]]; then
      curl -Lo "$NDK_ZIP" \
        "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip"
    fi
    mkdir -p "$(dirname "$ANDROID_NDK_DIR")"
    unzip -qo "$NDK_ZIP" -d "$(dirname "$ANDROID_NDK_DIR")"
    rm -f "$NDK_ZIP"
    echo "    NDK installed."
  else
    echo "    Android NDK already present, skipping install."
  fi
else
  echo ">>> [1/6] Skipping SDK/NDK install (--skip-sdk-install set)."
fi

export ANDROID_HOME="$ANDROID_SDK_DIR"
export ANDROID_NDK_HOME="$ANDROID_NDK_DIR"

# --------------------------------------------------------------------------- #
# Step 2: Patch WORKSPACE with android_sdk_repository / android_ndk_repository#
# --------------------------------------------------------------------------- #
echo ""
echo ">>> [2/6] Patching WORKSPACE with Android SDK/NDK paths ..."
cd "$MEDIAPIPE_ROOT"

# Ensure Bazel output root points to large disk (idempotent)
mkdir -p "$BAZEL_OUTPUT_ROOT"
sed -i '/startup --output_user_root/d' .bazelrc
sed -i "1s|^|startup --output_user_root=${BAZEL_OUTPUT_ROOT}\n|" .bazelrc
echo "    Bazel output root: $BAZEL_OUTPUT_ROOT"

# Remove stale entries and re-add fresh ones
sed -i '/^android_sdk_repository(/,/^)/d' WORKSPACE
sed -i '/^android_ndk_repository(/,/^)/d' WORKSPACE
sed -i '/^bind(name = "android\/crosstool"/d' WORKSPACE

cat >> WORKSPACE << EOF

android_sdk_repository(
    name = "androidsdk",
    path = "${ANDROID_SDK_DIR}",
    api_level = ${SDK_API_LEVEL},
    build_tools_version = "${BUILD_TOOLS_VERSION}",
)

android_ndk_repository(
    name = "androidndk",
    path = "${ANDROID_NDK_DIR}",
    api_level = 24,
)

bind(name = "android/crosstool", actual = "@androidndk//:toolchain")
EOF
echo "    WORKSPACE updated."

# --------------------------------------------------------------------------- #
# Step 3: Stage Arm NN prebuilt .so files and headers                        #
# --------------------------------------------------------------------------- #
echo ""
echo ">>> [3/6] Staging Arm NN prebuilt libraries ..."

ARMNN_STAGED_LIB="$MEDIAPIPE_ROOT/third_party/armnn/lib/arm64-v8a"
ARMNN_STAGED_INC="$MEDIAPIPE_ROOT/third_party/armnn/include"
mkdir -p "$ARMNN_STAGED_LIB" "$ARMNN_STAGED_INC"

# .so files — use cp -L to dereference symlinks and copy real binaries.
# Bazel cc_import requires actual files, not dangling symlink chains.
for lib in \
  "$ARMNN_BUILD_DIR/libarmnn.so.35.0" \
  "$ARMNN_BUILD_DIR/delegate/libarmnnDelegate.so.29.1" \
  "$ETHOSN_INSTALL_DIR/lib/libEthosNDriver.so" \
  "$ETHOSN_INSTALL_DIR/lib/libEthosNSupport.so"; do
  if [[ -e "$lib" ]]; then
    cp -L "$lib" "$ARMNN_STAGED_LIB/"
    echo "    staged: $(basename "$lib")"
  else
    echo "    WARNING: $lib not found, skipping."
  fi
done

# Headers — staged flat into include/ (matches #include "armnn_delegate.hpp" etc.)
for dir in armnn armnnUtils armnnDeserializer armnnSerializer armnnTfLiteParser armnnOnnxParser; do
  cp -rT "$ARMNN_SRC_DIR/include/$dir" "$ARMNN_STAGED_INC/$dir" 2>/dev/null || true
done
cp "$ARMNN_SRC_DIR/delegate/classic/include/armnn_delegate.hpp" "$ARMNN_STAGED_INC/" 2>/dev/null || true
cp "$ARMNN_SRC_DIR/delegate/common/include/DelegateOptions.hpp"  "$ARMNN_STAGED_INC/" 2>/dev/null || true
# Patch armnn_delegate.hpp: change <tensorflow/lite/...> angle-bracket includes
# to "tensorflow/lite/..." quote includes so Bazel sandbox can resolve them.
python3 -c "
import re, pathlib, sys
p = pathlib.Path(sys.argv[1])
txt = p.read_text()
txt = re.sub(r'#include <(tensorflow/lite[^>]+)>', r'#include \"\1\"', txt)
p.write_text(txt)
" "$ARMNN_STAGED_INC/armnn_delegate.hpp"
echo "    Headers staged and patched."
echo "    Headers staged."

# --------------------------------------------------------------------------- #
# Step 4: Ensure Bazelisk / Bazel is available                               #
# --------------------------------------------------------------------------- #
echo ""
echo ">>> [4/5] Checking for Bazel / Bazelisk ..."

_install_bazelisk() {
  local version="1.25.0"
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *)        echo "  WARN: unknown arch $arch, attempting amd64"; arch="amd64" ;;
  esac
  local url="https://github.com/bazelbuild/bazelisk/releases/download/v${version}/bazelisk-linux-${arch}"
  local dest="$HOME/.local/bin/bazelisk"
  mkdir -p "$(dirname "$dest")"
  echo "  Downloading bazelisk v${version} (${arch}) ..."
  curl -fsSLo "$dest" "$url"
  chmod +x "$dest"
  export PATH="$HOME/.local/bin:$PATH"
  echo "  Bazelisk installed to $dest"
}

if command -v bazelisk &>/dev/null; then
  BAZEL=bazelisk
  echo "  Found bazelisk: $(command -v bazelisk)"
elif command -v bazel &>/dev/null; then
  BAZEL=bazel
  echo "  Found bazel: $(command -v bazel)"
else
  echo "  Neither 'bazel' nor 'bazelisk' found — installing bazelisk ..."
  _install_bazelisk
  BAZEL=bazelisk
fi

echo "  Bazel command: $BAZEL ($(${BAZEL} version 2>/dev/null | head -1 || echo 'version check skipped'))"

# --------------------------------------------------------------------------- #
# Step 5: Build the AARs                                                      #
# --------------------------------------------------------------------------- #
echo ""
echo ">>> [5/5] Building AARs with Bazel ..."

cd "$MEDIAPIPE_ROOT"

# ----- Build tasks_core AAR (includes JNI .so + all Java protos) -----
echo ""
echo "  Building tasks_core.aar ..."
$BAZEL --output_user_root="$BAZEL_OUTPUT_ROOT" build -c opt \
  --config=android_arm64 \
  --define=arm_npu=1 \
  --define=xnn_enable_avx512amx=false \
  //mediapipe/tasks/java/com/google/mediapipe/tasks/core:tasks_core

# ----- Build tasks_vision AAR -----
echo ""
echo "  Building tasks_vision.aar ..."
$BAZEL --output_user_root="$BAZEL_OUTPUT_ROOT" build -c opt \
  --config=android_arm64 \
  --define=arm_npu=1 \
  --define=xnn_enable_avx512amx=false \
  //mediapipe/tasks/java/com/google/mediapipe/tasks/vision:tasks_vision

# --------------------------------------------------------------------------- #
# Output summary                                                               #
# --------------------------------------------------------------------------- #
echo ""
echo "============================================================"
echo "  Build complete!"
echo "============================================================"
echo ""
echo "  Output AARs:"

CORE_AAR="$MEDIAPIPE_ROOT/bazel-bin/mediapipe/tasks/java/com/google/mediapipe/tasks/core/tasks_core.aar"
VISION_AAR="$MEDIAPIPE_ROOT/bazel-bin/mediapipe/tasks/java/com/google/mediapipe/tasks/vision/tasks_vision.aar"

if [[ -f "$CORE_AAR" ]]; then
  echo "    $CORE_AAR"
else
  echo "    WARNING: tasks_core.aar not found at expected path."
fi

if [[ -f "$VISION_AAR" ]]; then
  echo "    $VISION_AAR"
else
  echo "    WARNING: tasks_vision.aar not found at expected path."
fi

echo ""
echo "  To verify the NPU JNI library is bundled inside the AAR:"
echo "    unzip -l $VISION_AAR | grep -E '\.so|jni'"
echo ""
echo "  Copy into your Android project:"
echo "    cp $CORE_AAR   <your_project>/app/libs/"
echo "    cp $VISION_AAR <your_project>/app/libs/"
echo ""
echo "  In your app/build.gradle:"
echo "    implementation fileTree(dir: 'libs', include: ['*.aar'])"
echo ""
echo "  To use the Arm NN / Ethos-N78 NPU delegate from Java:"
echo "    BaseOptions baseOptions = BaseOptions.builder()"
echo "        .setDelegate(Delegate.NPU)"
echo "        .setModelAssetPath(\"model.tflite\")"
echo "        .build();"
echo "============================================================"
