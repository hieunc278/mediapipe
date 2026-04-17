#!/usr/bin/env bash
# publish_aar_to_github_packages.sh
#
# Publishes tasks_core.aar and tasks_vision.aar directly from the local build
# machine to GitHub Packages (Maven).
#
# Prerequisites:
#   - Maven installed: sudo apt install maven
#   - A GitHub Personal Access Token (PAT) with write:packages scope
#     set in env var GITHUB_TOKEN, or passed as argument
#
# Usage:
#   export GITHUB_TOKEN=ghp_xxxxxxxxxxxx
#   ./publish_aar_to_github_packages.sh 0.10.35-ethos-n78.1
#
set -euo pipefail

VERSION="${1:-0.10.35-ethos-n78.1}"
GITHUB_USER="hieunc278"
REPO="mediapipe"
GROUP_ID="io.github.hieunc278.mediapipe"
REPO_URL="https://maven.pkg.github.com/${GITHUB_USER}/${REPO}"

CORE_AAR="bazel-bin/mediapipe/tasks/java/com/google/mediapipe/tasks/core/tasks_core.aar"
VISION_AAR="bazel-bin/mediapipe/tasks/java/com/google/mediapipe/tasks/vision/tasks_vision.aar"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "ERROR: Set GITHUB_TOKEN to a GitHub PAT with write:packages scope."
  echo "       export GITHUB_TOKEN=ghp_xxxxxxxxxxxx"
  exit 1
fi

if [[ ! -f "$CORE_AAR" ]] || [[ ! -f "$VISION_AAR" ]]; then
  echo "ERROR: AAR files not found. Run the build first:"
  echo "  ~/.local/bin/bazelisk build -c opt --config=android_arm64 \\"
  echo "    --define=arm_npu=1 --define=xnn_enable_avx512amx=false \\"
  echo "    //mediapipe/tasks/java/com/google/mediapipe/tasks/core:tasks_core \\"
  echo "    //mediapipe/tasks/java/com/google/mediapipe/tasks/vision:tasks_vision"
  exit 1
fi

# Write a temporary Maven settings.xml with the token
SETTINGS_FILE="$(mktemp /tmp/mvn-settings-XXXX.xml)"
trap "rm -f $SETTINGS_FILE" EXIT

cat > "$SETTINGS_FILE" <<EOF
<settings>
  <servers>
    <server>
      <id>github</id>
      <username>${GITHUB_USER}</username>
      <password>${GITHUB_TOKEN}</password>
    </server>
  </servers>
</settings>
EOF

deploy() {
  local FILE="$1"
  local ARTIFACT_ID="$2"
  echo ""
  echo "▶ Publishing ${ARTIFACT_ID}:${VERSION} ..."
  mvn deploy:deploy-file \
    -s "$SETTINGS_FILE" \
    -Dfile="$FILE" \
    -DgroupId="$GROUP_ID" \
    -DartifactId="$ARTIFACT_ID" \
    -Dversion="$VERSION" \
    -Dpackaging=aar \
    -DgeneratePom=true \
    -DrepositoryId=github \
    -Durl="$REPO_URL"
  echo "✓ ${ARTIFACT_ID}:${VERSION} published."
}

deploy "$CORE_AAR"   "tasks-core-npu"
deploy "$VISION_AAR" "tasks-vision-npu"

echo ""
echo "════════════════════════════════════════════════════════════"
echo " Published to GitHub Packages:"
echo "   ${GROUP_ID}:tasks-core-npu:${VERSION}"
echo "   ${GROUP_ID}:tasks-vision-npu:${VERSION}"
echo ""
echo " Consumers add to settings.gradle:"
echo "   maven {"
echo "     url = uri(\"https://maven.pkg.github.com/hieunc278/mediapipe\")"
echo "     credentials {"
echo "       username = \"\${GITHUB_USER}\""
echo "       password = \"\${GITHUB_TOKEN}\""   # PAT with read:packages
echo "     }"
echo "   }"
echo ""
echo " And to build.gradle:"
echo "   implementation '${GROUP_ID}:tasks-core-npu:${VERSION}'"
echo "   implementation '${GROUP_ID}:tasks-vision-npu:${VERSION}'"
echo "════════════════════════════════════════════════════════════"
