# MediaPipe Tasks AAR with Arm Ethos-N78 NPU Support — Build Notes

**Target platform**: Telechips TCC805x, `arm64-v8a`, Android  
**NPU**: Arm Ethos-N78 via Arm NN `EthosNAcc` backend  
**Build date**: April 17, 2026  
**Bazel**: 7.4.1 (via Bazelisk 1.25.0)  
**NDK**: 27.0.12077973 · **SDK**: android-35  

---

## Build Output Artifacts

| File | Size | Contents |
|------|------|----------|
| `bazel-bin/.../tasks/core/tasks_core.aar` | 5.6 MB | `classes.jar` + `jni/arm64-v8a/libmediapipe_tasks_jni.so` (12 MB uncompressed) |
| `bazel-bin/.../tasks/vision/tasks_vision.aar` | 222 KB | `classes.jar` + vision Java APIs (no native code — by design) |

**Full paths:**
```
bazel-bin/mediapipe/tasks/java/com/google/mediapipe/tasks/core/tasks_core.aar
bazel-bin/mediapipe/tasks/java/com/google/mediapipe/tasks/vision/tasks_vision.aar
```

---

## Build Command

```bash
cd /mnt/disk1/telechips/mediapipe

~/.local/bin/bazelisk build -c opt \
  --config=android_arm64 \
  --define=arm_npu=1 \
  --define=xnn_enable_avx512amx=false \
  //mediapipe/tasks/java/com/google/mediapipe/tasks/core:tasks_core \
  //mediapipe/tasks/java/com/google/mediapipe/tasks/vision:tasks_vision
```

> **Note**: `tasks_vision.aar` contains only Java. The `.so` is in `tasks_core.aar`.

---

## Issues Resolved During Build

### 1. Bazelisk / LLVM overlay timeout
**Symptom**: `com.google.devtools.build.lib.analysis.config.InvalidConfigurationException` downloading LLVM toolchain overlays.  
**Fix**: Added to `.bazelrc`:
```
common --experimental_scale_timeouts=10.0
```

---

### 2. Bazel cache on NTFS filesystem
**Symptom**: Bazel failed with inotify / symlink errors when cache was on a Windows-shared NTFS mount.  
**Fix**: Redirected cache to ext4:
```
# ~/.bazelrc
startup --output_user_root=/home/hieunc4cdc/.cache/bazel
```

---

### 3. Disk full during dependency fetch
**Symptom**: `No space left on device` during LLVM/TFLite fetches.  
**Fix**: Freed ~32 GB by deleting stale package caches:
```bash
rm -rf ~/.cache/uv      # 23 GB
rm -rf ~/.cache/pip     # 9.4 GB
```

---

### 4. Arm NN `.so` files staged as symlinks
**Symptom**: Bazel sandbox could not access the `.so` files because they were dangling or relative symlinks.  
**Fix**: Copied real binaries with `-L` (dereference):
```bash
cp -L /mnt/disk1/telechips/armnn/build/libarmnn.so.35.0 \
      third_party/armnn/lib/arm64-v8a/libarmnn.so.35.0
cp -L /mnt/disk1/telechips/armnn/build/libarmnnDelegate.so.29.1 \
      third_party/armnn/lib/arm64-v8a/libarmnnDelegate.so.29.1
```
Also created real-file copies of the SONAME aliases (not symlinks):
```bash
cp libarmnn.so.35.0     libarmnn.so.35
cp libarmnnDelegate.so.29.1 libarmnnDelegate.so.29
```

---

### 5. Wrong include paths for Arm NN headers
**Symptom**: Compiler couldn't find `armnn/...` headers — they were staged in a flat directory.  
**Fix**: Used `strip_include_prefix = "include"` in `BUILD.bazel` instead of `includes = [...]`:
```python
cc_library(
    name = "armnn",
    hdrs = glob(["include/armnn/**/*.hpp", ...]),
    strip_include_prefix = "include",   # ← correct for Bazel sandbox
)
```

---

### 6. Missing `armnnUtils/` headers
**Symptom**: `armnn/backends/TensorHandle.hpp` included `armnnUtils/DataLayoutIndexed.hpp` which was missing.  
**Fix**: Staged the full `armnnUtils/` directory from the Arm NN source:
```bash
cp -rL /mnt/disk1/telechips/armnn/include/armnnUtils \
       third_party/armnn/include/armnnUtils
```
And added it to `hdrs` glob in `BUILD.bazel`.

---

### 7. `cc_import` not propagating headers/libs to Android cross-compilation
**Symptom**: Compilation succeeded host-side but headers were invisible to the Android toolchain.  
**Fix**: Replaced `cc_import(...)` with `cc_library(srcs=[".so"], ...)` — Bazel's Android rules handle `cc_library` correctly:
```python
# Before (broken):
cc_import(name = "armnn", shared_library = "lib/.../libarmnn.so.35.0", ...)

# After (working):
cc_library(name = "armnn", srcs = ["lib/arm64-v8a/libarmnn.so.35"], ...)
```

---

### 8. `armnn_delegate.hpp` used angle-bracket TFLite includes
**Symptom**: `#include <tensorflow/lite/...>` failed in Bazel sandbox (only quote-includes work with `strip_include_prefix`).  
**Fix**: Patched `armnn_delegate.hpp` with Python regex to convert to quote includes:
```python
import re, pathlib
f = pathlib.Path("third_party/armnn/include/armnn_delegate.hpp")
f.write_text(re.sub(r'#include <(tensorflow/lite/[^>]+)>', r'#include "\1"', f.read_text()))
```

---

### 9. Duplicate rules in `BUILD.bazel`
**Symptom**: `Error in cc_library: Rule 'armnn' already exists`.  
**Fix**: Rewrote `third_party/armnn/BUILD.bazel` from scratch as a single clean file.

---

### 10. Linker undefined symbols — C++ STL ABI mismatch (root cause of all linker errors)
**Symptom**:
```
ld.lld: error: undefined symbol: armnnDelegate::DelegateOptions::DelegateOptions(
    std::__ndk1::vector<armnn::BackendId, std::__ndk1::allocator<armnn::BackendId>> const&, ...)
```
**Root cause**: The Arm NN prebuilt `.so` files were compiled with **GNU libstdc++** (symbols export `std::__cxx11::...`), but the Android NDK build uses **LLVM libc++** (symbols use `std::__ndk1::...`). These are **incompatible ABIs** — the linker cannot satisfy the C++ symbols at link time.  

**Fix**: Replaced the direct C++ Arm NN API with the **TfLite External Delegate C API** (`TfLiteExternalDelegateCreate`), which is a pure-C interface using `dlopen` internally — zero C++ STL boundary:

```cpp
// inference_calculator_cpu.cc — before (broken: C++ ABI mismatch)
#include "armnn_delegate.hpp"
armnnDelegate::DelegateOptions opts({"EthosNAcc", "CpuRef"});
armnnDelegate::TfLiteArmnnDelegateCreate(opts);

// after (working: pure C API, no STL boundary)
#include "tensorflow/lite/delegates/external/external_delegate.h"
TfLiteExternalDelegateOptions opts = TfLiteExternalDelegateOptionsDefault(lib_path.c_str());
TfLiteExternalDelegateOptionsInsert(&opts, "backends", "EthosNAcc,CpuRef");
TfLiteExternalDelegateCreate(&opts);
```

BUILD dep changed from `//third_party/armnn:armnn_delegate` to:
```python
"@org_tensorflow//tensorflow/lite/delegates/external:external_delegate"
```

---

## Files Modified

| File | Change |
|------|--------|
| `.bazelrc` | Added `startup --output_user_root`, `--experimental_scale_timeouts=10.0` |
| `third_party/armnn/BUILD.bazel` | New file: `cc_library` rules with `strip_include_prefix`, real `.so` srcs |
| `third_party/armnn/include/armnn_delegate.hpp` | Patched angle-bracket → quote TFLite includes |
| `mediapipe/BUILD` | Added `config_setting(name="arm_npu", define_values={"arm_npu":"1"})` |
| `mediapipe/calculators/tensor/inference_calculator_cpu.cc` | Added NPU delegate block using External Delegate C API |
| `mediapipe/calculators/tensor/BUILD` | Added `arm_npu` select for `local_defines` and `deps` |
| `mediapipe/calculators/tensor/inference_calculator.proto` | Added `Npu` delegate message |
| `mediapipe/tasks/cc/core/proto/acceleration.proto` | Added `npu` field to `Acceleration` oneof |
| `mediapipe/tasks/cc/core/base_options.h` | Added `NPU` enum + `NpuOptions` struct |
| `mediapipe/tasks/cc/core/base_options.cc` | Added `NPU` case to delegate converter |
| `mediapipe/tasks/java/.../TaskOptions.java` | Added `NPU` case + `setDelegateOptions(NpuOptions)` |

---

## Deployment Guide

### Step 1 — Copy AARs into your Android project

```
your-android-app/
  app/libs/
    tasks_core.aar       ← from bazel-bin/.../tasks/core/tasks_core.aar
    tasks_vision.aar     ← from bazel-bin/.../tasks/vision/tasks_vision.aar
```

In `app/build.gradle`:
```groovy
repositories {
    flatDir { dirs 'libs' }
}
dependencies {
    implementation(name: 'tasks_core', ext: 'aar')
    implementation(name: 'tasks_vision', ext: 'aar')
    // required transitive deps
    implementation 'com.google.protobuf:protobuf-javalite:3.19.4'
    implementation 'com.google.guava:guava:31.0.1-android'
}
```

---

### Step 2 — Bundle Arm NN native libraries

The Arm NN `.so` files **are not** inside the AARs (to avoid ABI mismatch). They must be shipped separately and loaded at runtime via `dispatch_library_directory`.

**Option A — Distribute via `jniLibs/` (recommended for production)**

Copy all four files into your app's `jniLibs`:
```
app/src/main/jniLibs/arm64-v8a/
  libarmnn.so              ← rename of libarmnn.so.35.0  (SONAME: libarmnn.so.35)
  libarmnn.so.35           ← real copy of libarmnn.so.35.0
  libarmnnDelegate.so      ← rename of libarmnnDelegate.so.29.1
  libarmnnDelegate.so.29   ← real copy of libarmnnDelegate.so.29.1
  libEthosNSupport.so
  libEthosNDriver.so
```

> Source files are in `third_party/armnn/lib/arm64-v8a/` after staging.

At runtime the libraries are installed to the app's native library directory. Pass that path to MediaPipe:
```java
String nativeLibDir = getApplicationInfo().nativeLibraryDir;
// e.g. /data/app/com.example.myapp-.../lib/arm64
```

**Option B — Push manually for testing (adb)**
```bash
DEVICE_LIB=/data/local/tmp/armnn

adb push third_party/armnn/lib/arm64-v8a/libarmnn.so.35        $DEVICE_LIB/libarmnn.so
adb push third_party/armnn/lib/arm64-v8a/libarmnn.so.35        $DEVICE_LIB/libarmnn.so.35
adb push third_party/armnn/lib/arm64-v8a/libarmnnDelegate.so.29 $DEVICE_LIB/libarmnnDelegate.so
adb push third_party/armnn/lib/arm64-v8a/libarmnnDelegate.so.29 $DEVICE_LIB/libarmnnDelegate.so.29
adb push third_party/armnn/lib/arm64-v8a/libEthosNSupport.so   $DEVICE_LIB/
adb push third_party/armnn/lib/arm64-v8a/libEthosNDriver.so    $DEVICE_LIB/
```

---

### Step 3 — Use NPU delegate in Java

```java
import com.google.mediapipe.tasks.core.BaseOptions;
import com.google.mediapipe.tasks.core.BaseOptions.Delegate;
import com.google.mediapipe.tasks.core.BaseOptions.NpuOptions;
import com.google.mediapipe.tasks.vision.imageclassifier.ImageClassifier;

// Get the directory where libarmnnDelegate.so lives at runtime
String nativeLibDir = context.getApplicationInfo().nativeLibraryDir;

BaseOptions baseOptions = BaseOptions.builder()
    .setModelAssetPath("model.tflite")
    .setDelegate(Delegate.NPU)
    .setDelegateOptions(new NpuOptions(nativeLibDir))
    .build();

ImageClassifier classifier = ImageClassifier.createFromOptions(context,
    ImageClassifierOptions.builder()
        .setBaseOptions(baseOptions)
        .build());
```

---

### Step 4 — Runtime library loading order

`libarmnnDelegate.so` is loaded by TFLite's external delegate mechanism (`dlopen`). It in turn depends on:
- `libarmnn.so.35` → `libarmnnDelegate.so.29`
- `libEthosNSupport.so` → Ethos-N kernel driver interface
- `libEthosNDriver.so` → user-space NPU driver

If using `jniLibs/`, Android's linker resolves these automatically from the same directory. If using `adb push`, ensure all files are in the same directory and it is readable.

---

### Arm NN Library Versions

| Library | File | SONAME |
|---------|------|--------|
| Arm NN runtime | `libarmnn.so.35.0` | `libarmnn.so.35` |
| Arm NN TFLite delegate | `libarmnnDelegate.so.29.1` | `libarmnnDelegate.so.29` |
| Ethos-N support lib | `libEthosNSupport.so` | — |
| Ethos-N driver | `libEthosNDriver.so` | — |

---

### Rebuild from Scratch

```bash
cd /mnt/disk1/telechips/mediapipe

# Optional: clean previous outputs
~/.local/bin/bazelisk clean --expunge

# Build both AARs
~/.local/bin/bazelisk build -c opt \
  --config=android_arm64 \
  --define=arm_npu=1 \
  --define=xnn_enable_avx512amx=false \
  //mediapipe/tasks/java/com/google/mediapipe/tasks/core:tasks_core \
  //mediapipe/tasks/java/com/google/mediapipe/tasks/vision:tasks_vision

# Verify
unzip -l bazel-bin/mediapipe/tasks/java/com/google/mediapipe/tasks/core/tasks_core.aar | grep jni
```

---

## Publishing AAR Artifacts to GitHub Packages

Published coordinates:

| Artifact | groupId | artifactId |
|----------|---------|------------|
| `tasks_core.aar` | `io.github.hieunc278.mediapipe` | `tasks-core-npu` |
| `tasks_vision.aar` | `io.github.hieunc278.mediapipe` | `tasks-vision-npu` |

Repository URL: `https://maven.pkg.github.com/hieunc278/mediapipe`

---

### Option A — Publish from local build machine

**Prerequisites:**

```bash
sudo apt install maven      # install Maven
# Create a GitHub PAT at https://github.com/settings/tokens
# Required scope: write:packages
```

**Run:**

```bash
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx
cd /mnt/disk1/telechips/mediapipe
./publish_aar_to_github_packages.sh 0.10.35-ethos-n78.1
```

The script will:
1. Write a temporary `settings.xml` with your token
2. Call `mvn deploy:deploy-file` for each AAR
3. Print consumer Gradle snippets on success

---

### Option B — GitHub Actions CI (automated)

Workflow: `.github/workflows/publish-npu-aar.yml`  
Triggers: tag push matching `npu-v*` **or** manual dispatch from Actions tab.

**One-time setup — upload Arm NN binaries as a GitHub Release asset:**

```bash
cd /mnt/disk1/telechips/mediapipe/third_party/armnn/lib/arm64-v8a

# Pack the real .so files (no symlinks)
tar -czf armnn-libs-arm64-v8a.tar.gz \
  libarmnn.so.35.0 libarmnn.so.35 \
  libarmnnDelegate.so.29.1 libarmnnDelegate.so.29 \
  libEthosNSupport.so libEthosNDriver.so

# Create a GitHub Release tagged "armnn-libs" and upload
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
gh release create armnn-libs armnn-libs-arm64-v8a.tar.gz \
  --repo hieunc278/mediapipe \
  --title "Arm NN prebuilt libs (arm64-v8a)" \
  --notes "Arm NN v35 + delegate v29 + Ethos-N support/driver .so files"
```

> Do this once (or when the Arm NN version changes). CI downloads this asset before every build.

**Trigger a publish via tag:**

```bash
git tag npu-v0.10.35-ethos-n78.1
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
git push myfork npu-v0.10.35-ethos-n78.1
```

Or: `https://github.com/hieunc278/mediapipe/actions` → **Publish NPU AAR to GitHub Packages** → **Run workflow**

---

### Consuming the Published AARs in an Android Project

**`settings.gradle`:**

```groovy
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://maven.pkg.github.com/hieunc278/mediapipe")
            credentials {
                username = System.getenv("GITHUB_USER") ?: project.findProperty("gpr.user")
                password = System.getenv("GITHUB_TOKEN") ?: project.findProperty("gpr.token")
            }
        }
    }
}
```

Store credentials in `~/.gradle/gradle.properties` (never commit this file):

```properties
gpr.user=hieunc278
gpr.token=ghp_xxxxxxxxxxxx
```

**`app/build.gradle`:**

```groovy
android {
    defaultConfig {
        ndk { abiFilters 'arm64-v8a' }
    }
}

dependencies {
    implementation 'io.github.hieunc278.mediapipe:tasks-core-npu:0.10.35-ethos-n78.1'
    implementation 'io.github.hieunc278.mediapipe:tasks-vision-npu:0.10.35-ethos-n78.1'
    // Required transitive deps
    implementation 'com.google.protobuf:protobuf-javalite:3.19.4'
    implementation 'com.google.guava:guava:31.0.1-android'
    implementation 'androidx.annotation:annotation:1.7.0'
}
```

---

### Shipping Arm NN Runtime Libraries to Consumers

The AARs do **not** bundle the Arm NN `.so` files. Consumers must ship them:

**Add to `app/src/main/jniLibs/arm64-v8a/`:**

```
libarmnn.so              ← copy of libarmnn.so.35.0
libarmnn.so.35           ← copy of libarmnn.so.35.0
libarmnnDelegate.so      ← copy of libarmnnDelegate.so.29.1
libarmnnDelegate.so.29   ← copy of libarmnnDelegate.so.29.1
libEthosNSupport.so
libEthosNDriver.so
```

Pass the runtime directory to MediaPipe:

```java
String nativeLibDir = context.getApplicationInfo().nativeLibraryDir;

BaseOptions baseOptions = BaseOptions.builder()
    .setModelAssetPath("model.tflite")
    .setDelegate(Delegate.NPU)
    .setDelegateOptions(new NpuOptions(nativeLibDir))
    .build();
```

---

### Version Naming Convention

```
<mediapipe-version>-ethos-n78.<patch>
```

| Version | Meaning |
|---------|---------|
| `0.10.35-ethos-n78.1` | First release based on MediaPipe 0.10.35 |
| `0.10.35-ethos-n78.2` | Bug-fix, same upstream base |
| `0.10.36-ethos-n78.1` | Rebased on MediaPipe 0.10.36 |
