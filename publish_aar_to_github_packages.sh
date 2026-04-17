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
  echo "ERROR: Set GITHUB_TOKEN to a GitHub classic PAT with write:packages scope."
  echo "       export GITHUB_TOKEN=ghp_xxxxxxxxxxxx"
  echo "  Create one at: https://github.com/settings/tokens (use 'Tokens (classic)')"
  exit 1
fi

# Fine-grained PATs (github_pat_...) do NOT work with GitHub Packages Maven.
# Only classic PATs (ghp_...) are supported.
if [[ "${GITHUB_TOKEN}" == github_pat_* ]]; then
  echo "ERROR: Fine-grained PATs (github_pat_...) are NOT supported by GitHub Packages Maven."
  echo "  You must use a classic PAT (ghp_...)."
  echo "  Create one at: https://github.com/settings/tokens → 'Tokens (classic)'"
  echo "  Required scopes: repo, write:packages, read:packages"
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

# Validate token has packages access before attempting deploy
echo "▶ Validating GitHub token access to packages ..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "${GITHUB_USER}:${GITHUB_TOKEN}" \
  "https://maven.pkg.github.com/${GITHUB_USER}/${REPO}/")
if [[ "$HTTP_STATUS" == "401" ]]; then
  echo "ERROR: Authentication failed (HTTP 401). Token is invalid or expired."
  echo "  Regenerate at: https://github.com/settings/tokens"
  exit 1
elif [[ "$HTTP_STATUS" == "403" ]]; then
  echo "ERROR: Authorization failed (HTTP 403). Your PAT needs ALL of these scopes:"
  echo "    write:packages, read:packages, repo"
  echo "  Regenerate at: https://github.com/settings/tokens"
  exit 1
fi
echo "✓ Token OK (HTTP ${HTTP_STATUS} — 404 is normal if no packages published yet)"

# Write a temporary Maven settings.xml with the token
# IMPORTANT: no leading whitespace inside heredoc — spaces corrupt XML parsing
SETTINGS_FILE="$(mktemp /tmp/mvn-settings-XXXX.xml)"
trap "rm -f $SETTINGS_FILE" EXIT

cat > "$SETTINGS_FILE" << MAVEN_EOF
<settings>
  <servers>
    <server>
      <id>github</id>
      <username>${GITHUB_USER}</username>
      <password>${GITHUB_TOKEN}</password>
    </server>
  </servers>
</settings>
MAVEN_EOF

# Verify the token was actually written into the settings file (catches empty token)
if ! grep -q "ghp_\|github_pat_\|ghs_" "$SETTINGS_FILE"; then
  echo "ERROR: GITHUB_TOKEN was not written into settings.xml."
  echo "  Make sure you exported it in the SAME shell session:"
  echo "    export GITHUB_TOKEN=ghp_xxxxxxxxxxxx"
  echo "  Current shell value: '${GITHUB_TOKEN:-<empty>}'"
  exit 1
fi
echo "✓ settings.xml written to $SETTINGS_FILE"

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
    -Durl="$REPO_URL" 2>&1 | tee /tmp/mvn-deploy-out.txt; MVN_EXIT=${PIPESTATUS[0]}
  if [[ $MVN_EXIT -ne 0 ]]; then
    if grep -q "409 Conflict" /tmp/mvn-deploy-out.txt; then
      echo ""
      echo "ERROR: Version ${VERSION} already exists in GitHub Packages (409 Conflict)."
      echo "  GitHub Packages does not allow overwriting a published version."
      echo "  → Use a new version: ./publish_aar_to_github_packages.sh ${VERSION%.*}.$((${VERSION##*.}+1))"
      echo "  → Or delete it at: https://github.com/${GITHUB_USER}/${REPO}/packages"
    else
      echo ""
      echo "ERROR: Deploy failed for ${ARTIFACT_ID}. Settings file: $SETTINGS_FILE"
    fi
    trap - EXIT; exit 1
  fi
  echo "✓ ${ARTIFACT_ID}:${VERSION} published."
}

deploy "$CORE_AAR"   "tasks-core-npu"
deploy "$VISION_AAR" "tasks-vision-npu"

# ── Publish Arm NN .so files as Maven artifacts ──────────────────────────────
# Each .so is published as packaging=so so consumers can pull them via Gradle.
LIB_DIR="third_party/armnn/lib/arm64-v8a"
deploy_so() {
  local FILE="$1"
  local ARTIFACT_ID="$2"
  if [[ ! -f "$FILE" ]]; then
    echo "⚠ Skipping ${ARTIFACT_ID}: file not found at ${FILE}"
    return
  fi
  echo ""
  echo "▶ Publishing ${ARTIFACT_ID}:${VERSION} ..."
  mvn deploy:deploy-file \
    -s "$SETTINGS_FILE" \
    -Dfile="$FILE" \
    -DgroupId="$GROUP_ID" \
    -DartifactId="$ARTIFACT_ID" \
    -Dversion="$VERSION" \
    -Dpackaging=so \
    -DgeneratePom=true \
    -DrepositoryId=github \
    -Durl="$REPO_URL" 2>&1 | tee /tmp/mvn-deploy-out.txt; MVN_EXIT=${PIPESTATUS[0]}
  if [[ $MVN_EXIT -ne 0 ]]; then
    if grep -q "409 Conflict" /tmp/mvn-deploy-out.txt; then
      echo ""
      echo "ERROR: Version ${VERSION} already exists for ${ARTIFACT_ID} (409 Conflict)."
      echo "  → Use a new version or delete at: https://github.com/${GITHUB_USER}/${REPO}/packages"
    else
      echo ""
      echo "ERROR: Deploy failed for ${ARTIFACT_ID}. Settings file: $SETTINGS_FILE"
    fi
    trap - EXIT; exit 1
  fi
  echo "✓ ${ARTIFACT_ID}:${VERSION} published."
}

deploy_so "${LIB_DIR}/libarmnn.so.35.0"          "armnn-native-arm64-v8a"
deploy_so "${LIB_DIR}/libarmnnDelegate.so.29.1"  "armnn-delegate-native-arm64-v8a"
deploy_so "${LIB_DIR}/libEthosNSupport.so"        "ethos-n-support-native-arm64-v8a"
deploy_so "${LIB_DIR}/libEthosNDriver.so"         "ethos-n-driver-native-arm64-v8a"

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
