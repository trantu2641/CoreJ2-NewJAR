#!/usr/bin/env bash
#
# CoreJ2-NewJAR
# Prepare the embedded OpenJDK Mobile + FreeJ2ME runtime for iOS.
#
# Target:
#   iOS 16.4+
#   arm64 / aarch64
#
# IMPORTANT:
# mobile-support-20250106.zip may extract as:
#   support/support/libffi/...
#   support/support/cups-2.3.6/...
# This script normalizes that layout automatically.
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_ROOT="${ROOT_DIR}/build/ios-runtime-work"
RUNTIME_ROOT="${ROOT_DIR}/build/ios-runtime"
OPENJDK_DIR="${WORK_ROOT}/mobile"
SUPPORT_ROOT="${WORK_ROOT}/support"
FREEJ2ME_DIR="${WORK_ROOT}/freej2me"

BUILD_CONF="ios-aarch64-zero-release"
JDK_IMAGE_DIR="${OPENJDK_DIR}/build/${BUILD_CONF}/images/jdk"
STATIC_LIBS_DIR="${OPENJDK_DIR}/build/${BUILD_CONF}/images/static-libs"
JVM_LIB_DIR="${STATIC_LIBS_DIR}/lib/zero"

BOOTSTRAP_DIR="${ROOT_DIR}/JavaOne/Features/Emulator/Runtime/EmbeddedJVM/Bootstrap"

OPENJDK_REPO="https://github.com/openjdk/mobile.git"
FREEJ2ME_REPO="https://github.com/hex007/freej2me.git"
MOBILE_SUPPORT_URL="https://download2.gluonhq.com/mobile/mobile-support-20250106.zip"

log() {
    printf '\n[%s] %s\n' "CoreJ2 Runtime" "$*"
}

fail() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

find_java_home() {
    if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
        printf '%s\n' "${JAVA_HOME}"
        return
    fi

    if command -v /usr/libexec/java_home >/dev/null 2>&1; then
        local jh
        jh="$(/usr/libexec/java_home -v 26 2>/dev/null || true)"
        if [[ -n "${jh}" && -x "${jh}/bin/java" ]]; then
            printf '%s\n' "${jh}"
            return
        fi

        jh="$(/usr/libexec/java_home -v 27 2>/dev/null || true)"
        if [[ -n "${jh}" && -x "${jh}/bin/java" ]]; then
            printf '%s\n' "${jh}"
            return
        fi

        jh="$(/usr/libexec/java_home -v 28 2>/dev/null || true)"
        if [[ -n "${jh}" && -x "${jh}/bin/java" ]]; then
            printf '%s\n' "${jh}"
            return
        fi
    fi

    fail "Could not find JDK 26/27/28. Install JDK 26 in GitHub Actions."
}

JAVA_HOME="$(find_java_home)"
export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"

JAVA_VERSION="$("${JAVA_HOME}/bin/java" -version 2>&1 | head -n 1 || true)"
JAVA_MAJOR="$("${JAVA_HOME}/bin/java" -version 2>&1 \
    | sed -nE 's/.*version "([0-9]+).*/\1/p' | head -n 1)"

if [[ -z "${JAVA_MAJOR}" ]]; then
    fail "Could not determine Java version. ${JAVA_VERSION}"
fi

case "${JAVA_MAJOR}" in
    26|27|28)
        ;;
    *)
        fail "OpenJDK Mobile requires Boot JDK 26/27/28 for this build. Found Java ${JAVA_MAJOR}: ${JAVA_VERSION}"
        ;;
esac

log "Using JAVA_HOME=${JAVA_HOME}"
log "Using ${JAVA_VERSION}"

for cmd in git curl unzip rsync xcrun autoconf ant make; do
    need_cmd "${cmd}"
done

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"

[[ -d "${SDK_PATH}" ]] || fail "iPhoneOS SDK was not found."
log "iPhoneOS SDK: ${SDK_PATH}"
log "iPhoneOS SDK version: ${SDK_VERSION}"

mkdir -p "${WORK_ROOT}" "${RUNTIME_ROOT}"

# ---------------------------------------------------------------------------
# OpenJDK Mobile
# ---------------------------------------------------------------------------

if [[ ! -d "${OPENJDK_DIR}/.git" ]]; then
    log "Cloning OpenJDK Mobile..."
    rm -rf "${OPENJDK_DIR}"
    git clone --depth 1 "${OPENJDK_REPO}" "${OPENJDK_DIR}"
else
    log "OpenJDK Mobile already exists; keeping checkout."
fi

cd "${OPENJDK_DIR}"

# ---------------------------------------------------------------------------
# mobile-support
# ---------------------------------------------------------------------------

SUPPORT_ZIP="${WORK_ROOT}/mobile-support-20250106.zip"

if [[ ! -f "${SUPPORT_ZIP}" ]]; then
    log "Downloading mobile-support..."
    curl -L --fail --retry 3 --retry-delay 2 \
        -o "${SUPPORT_ZIP}" \
        "${MOBILE_SUPPORT_URL}"
else
    log "Using cached ${SUPPORT_ZIP}"
fi

rm -rf "${SUPPORT_ROOT}"
mkdir -p "${SUPPORT_ROOT}"

log "Extracting mobile-support..."
unzip -q "${SUPPORT_ZIP}" -d "${SUPPORT_ROOT}"

# mobile-support-20250106.zip currently extracts with an extra "support/"
# directory in the archive:
#
#   ${SUPPORT_ROOT}/support/libffi/...
#   ${SUPPORT_ROOT}/support/cups-2.3.6/...
#
# Some revisions/layouts may extract directly into ${SUPPORT_ROOT}.
# Detect both layouts instead of assuming one.

ACTUAL_SUPPORT_ROOT="${SUPPORT_ROOT}"

if [[ -d "${SUPPORT_ROOT}/support" ]]; then
    if [[ -d "${SUPPORT_ROOT}/support/libffi" || \
          -d "${SUPPORT_ROOT}/support/cups-2.3.6" ]]; then
        ACTUAL_SUPPORT_ROOT="${SUPPORT_ROOT}/support"
    fi
fi

LIBFFI_INCLUDE="${ACTUAL_SUPPORT_ROOT}/libffi/include"
LIBFFI_LIB="${ACTUAL_SUPPORT_ROOT}/libffi/libs"

# OpenJDK Mobile's --with-cups-include expects the directory containing
# "cups/cups.h", therefore:
#
#   --with-cups-include=/.../cups-2.3.6
#
# not ".../cups-2.3.6/cups" and not --with-cups=none.
CUPS_INCLUDE="${ACTUAL_SUPPORT_ROOT}/cups-2.3.6"
CUPS_HEADER="${CUPS_INCLUDE}/cups/cups.h"

log "mobile-support root: ${ACTUAL_SUPPORT_ROOT}"

[[ -d "${LIBFFI_INCLUDE}" ]] || \
    fail "libffi headers were not found at: ${LIBFFI_INCLUDE}"

[[ -d "${LIBFFI_LIB}" ]] || \
    fail "libffi libraries were not found at: ${LIBFFI_LIB}"

[[ -f "${CUPS_HEADER}" ]] || {
    log "CUPS header was not found at expected path:"
    log "  ${CUPS_HEADER}"
    log "CUPS-related files found:"
    find "${SUPPORT_ROOT}" -type f \( -name 'cups.h' -o -name 'libcups*.a' \) -print | head -n 100 || true
    fail "CUPS headers are missing from mobile-support."
}

log "libffi include: ${LIBFFI_INCLUDE}"
log "libffi libs:    ${LIBFFI_LIB}"
log "CUPS include:   ${CUPS_INCLUDE}"
log "CUPS header:    ${CUPS_HEADER}"

# ---------------------------------------------------------------------------
# Configure OpenJDK Mobile
# ---------------------------------------------------------------------------

cd "${OPENJDK_DIR}"

if [[ -d "build/${BUILD_CONF}" ]]; then
    log "Removing stale OpenJDK build configuration..."
    rm -rf "build/${BUILD_CONF}"
fi

log "Configuring OpenJDK Mobile for iOS arm64..."

bash ./configure \
    --disable-warnings-as-errors \
    --openjdk-target=aarch64-macos-ios \
    --with-boot-jdk="${JAVA_HOME}" \
    --with-libffi-include="${LIBFFI_INCLUDE}" \
    --with-libffi-lib="${LIBFFI_LIB}" \
    --with-cups-include="${CUPS_INCLUDE}" \
    --with-sysroot="${SDK_PATH}"

# ---------------------------------------------------------------------------
# Build static OpenJDK + JDK image
# ---------------------------------------------------------------------------

log "Building OpenJDK static libraries..."
make CONF="${BUILD_CONF}" static-libs-image

log "Building OpenJDK static JDK image..."
make CONF="${BUILD_CONF}" static-jdk-image

[[ -f "${JVM_LIB_DIR}/libjvm.a" ]] || {
    find "${OPENJDK_DIR}/build/${BUILD_CONF}" -name 'libjvm.a' -print | head -n 50 || true
    fail "libjvm.a was not produced."
}

[[ -d "${JDK_IMAGE_DIR}" ]] || \
    fail "Static JDK image was not produced: ${JDK_IMAGE_DIR}"

# ---------------------------------------------------------------------------
# Install runtime artifacts into CoreJ2
# ---------------------------------------------------------------------------

log "Installing OpenJDK runtime artifacts..."

rm -rf "${RUNTIME_ROOT}/jdk"
rm -rf "${RUNTIME_ROOT}/lib"
rm -rf "${RUNTIME_ROOT}/include"

mkdir -p \
    "${RUNTIME_ROOT}/jdk" \
    "${RUNTIME_ROOT}/lib" \
    "${RUNTIME_ROOT}/include"

rsync -a "${JDK_IMAGE_DIR}/" "${RUNTIME_ROOT}/jdk/"
rsync -a "${STATIC_LIBS_DIR}/" "${RUNTIME_ROOT}/lib/"

# JNI/JVM headers can be in multiple locations depending on OpenJDK revision.
HEADER_FOUND=0

for candidate in \
    "${OPENJDK_DIR}/src/java.base/share/native/include" \
    "${OPENJDK_DIR}/build/${BUILD_CONF}/support/modules_include/java.base"; do

    if [[ -f "${candidate}/jni.h" ]]; then
        rsync -a "${candidate}/" "${RUNTIME_ROOT}/include/"
        HEADER_FOUND=1
        break
    fi
done

if [[ "${HEADER_FOUND}" -ne 1 ]]; then
    find "${OPENJDK_DIR}/build/${BUILD_CONF}" \
        "${OPENJDK_DIR}/src" \
        -name jni.h -print 2>/dev/null | head -n 20 || true
    fail "jni.h could not be located."
fi

# Some native sources use jni_md.h from a platform-specific include folder.
for md in \
    "${OPENJDK_DIR}/src/java.base/share/native/include/darwin" \
    "${OPENJDK_DIR}/src/java.base/unix/native/include" \
    "${OPENJDK_DIR}/src/java.base/macosx/native/include"; do

    if [[ -f "${md}/jni_md.h" ]]; then
        rsync -a "${md}/" "${RUNTIME_ROOT}/include/"
    fi
done

# ---------------------------------------------------------------------------
# FreeJ2ME
# ---------------------------------------------------------------------------

if [[ ! -d "${FREEJ2ME_DIR}/.git" ]]; then
    log "Cloning FreeJ2ME..."
    rm -rf "${FREEJ2ME_DIR}"
    git clone --depth 1 "${FREEJ2ME_REPO}" "${FREEJ2ME_DIR}"
else
    log "FreeJ2ME already exists; keeping checkout."
fi

FREEJ2ME_SRC="${FREEJ2ME_DIR}/src"
FREEJ2ME_BUILD="${WORK_ROOT}/freej2me-build"
FREEJ2ME_CLASSES="${FREEJ2ME_BUILD}/classes"
FREEJ2ME_JAR="${RUNTIME_ROOT}/freej2me-core.jar"

[[ -d "${FREEJ2ME_SRC}" ]] || \
    fail "FreeJ2ME source directory was not found: ${FREEJ2ME_SRC}"

rm -rf "${FREEJ2ME_BUILD}"
mkdir -p "${FREEJ2ME_CLASSES}"

# Collect FreeJ2ME Java sources.
mapfile -t FREEJ2ME_JAVA_FILES < <(
    find "${FREEJ2ME_SRC}" -type f -name '*.java' | sort
)

((${#FREEJ2ME_JAVA_FILES[@]} > 0)) || \
    fail "No FreeJ2ME Java source files were found."

# Collect CoreJ2 bootstrap Java sources if present.
BOOTSTRAP_JAVA_FILES=()
if [[ -d "${BOOTSTRAP_DIR}" ]]; then
    while IFS= read -r -d '' f; do
        BOOTSTRAP_JAVA_FILES+=("${f}")
    done < <(find "${BOOTSTRAP_DIR}" -type f -name '*.java' -print0 | sort -z)
fi

ALL_JAVA_FILES=(
    "${FREEJ2ME_JAVA_FILES[@]}"
    "${BOOTSTRAP_JAVA_FILES[@]}"
)

log "Compiling ${#ALL_JAVA_FILES[@]} Java sources..."

# Prefer the runtime's javac if the JDK image contains one; otherwise use
# the Boot JDK's javac for the build-time compilation.
JAVAC_BIN="${JAVA_HOME}/bin/javac"

if [[ -x "${RUNTIME_ROOT}/jdk/bin/javac" ]]; then
    JAVAC_BIN="${RUNTIME_ROOT}/jdk/bin/javac"
fi

[[ -x "${JAVAC_BIN}" ]] || \
    fail "javac was not found."

"${JAVAC_BIN}" \
    -source 8 \
    -target 8 \
    -encoding UTF-8 \
    -d "${FREEJ2ME_CLASSES}" \
    "${ALL_JAVA_FILES[@]}"

log "Creating ${FREEJ2ME_JAR}..."

rm -f "${FREEJ2ME_JAR}"

(
    cd "${FREEJ2ME_CLASSES}"
    jar cf "${FREEJ2ME_JAR}" .
)

[[ -s "${FREEJ2ME_JAR}" ]] || \
    fail "freej2me-core.jar was not created."

# ---------------------------------------------------------------------------
# Generate CoreJ2Runtime.xcconfig
# ---------------------------------------------------------------------------

XCCONFIG_DIR="${RUNTIME_ROOT}"
XCCONFIG="${XCCONFIG_DIR}/CoreJ2Runtime.xcconfig"

# Gather static archives. Do not hard-code the complete OpenJDK archive list:
# OpenJDK Mobile can change it between revisions.
mapfile -t STATIC_ARCHIVES < <(
    find "${RUNTIME_ROOT}/lib" \
        -type f \
        \( -name '*.a' \) \
        -print | sort
)

LIBRARY_SEARCH_PATHS_LINE="LIBRARY_SEARCH_PATHS ="
for dir in "${RUNTIME_ROOT}/lib" \
           "${RUNTIME_ROOT}/lib/lib" \
           "${RUNTIME_ROOT}/lib/lib/zero"; do
    if [[ -d "${dir}" ]]; then
        LIBRARY_SEARCH_PATHS_LINE+=" \"${dir}\""
    fi
done

HEADER_SEARCH_PATHS_LINE="HEADER_SEARCH_PATHS ="
HEADER_SEARCH_PATHS_LINE+=" \"${RUNTIME_ROOT}/include\""
HEADER_SEARCH_PATHS_LINE+=" \"${LIBFFI_INCLUDE}\""

# Add any OpenJDK native include directories that contain JNI headers.
while IFS= read -r header_dir; do
    HEADER_SEARCH_PATHS_LINE+=" \"${header_dir}\""
done < <(
    find "${OPENJDK_DIR}/src" "${OPENJDK_DIR}/build/${BUILD_CONF}" \
        -type f -name 'jni.h' -print 2>/dev/null \
        | xargs -r -n1 dirname \
        | sort -u
)

{
    echo "// Generated by scripts/ios-runtime/prepare-runtime.sh"
    echo "// Do not edit manually."
    echo
    echo "COREJ2_RUNTIME_ROOT = \"${RUNTIME_ROOT}\""
    echo "COREJ2_RUNTIME_JDK = \"${RUNTIME_ROOT}/jdk\""
    echo "COREJ2_RUNTIME_JNI_INCLUDE = \"${RUNTIME_ROOT}/include\""
    echo "COREJ2_FREEJ2ME_JAR = \"${FREEJ2ME_JAR}\""
    echo
    echo "${HEADER_SEARCH_PATHS_LINE}"
    echo "${LIBRARY_SEARCH_PATHS_LINE}"
    echo
    echo "OTHER_LDFLAGS = \$(inherited) -lc++ -lz -liconv"
    echo
} > "${XCCONFIG}"

# Add explicit static libraries after the generic flags. Ordering is retained
# from the OpenJDK build output and can be consumed by the project xcconfig.
if ((${#STATIC_ARCHIVES[@]} > 0)); then
    {
        echo "// OpenJDK static archives:"
        for archive in "${STATIC_ARCHIVES[@]}"; do
            printf '// %s\n' "${archive}"
        done
    } >> "${XCCONFIG}"
fi

# ---------------------------------------------------------------------------
# Runtime manifest
# ---------------------------------------------------------------------------

MANIFEST="${RUNTIME_ROOT}/RUNTIME-MANIFEST.txt"

{
    echo "CoreJ2 embedded runtime"
    echo
    echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Repository root: ${ROOT_DIR}"
    echo "OpenJDK target: aarch64-macos-ios"
    echo "OpenJDK configuration: ${BUILD_CONF}"
    echo "iPhoneOS SDK: ${SDK_VERSION}"
    echo "Boot JDK: ${JAVA_VERSION}"
    echo
    echo "OpenJDK source: ${OPENJDK_REPO}"
    echo "FreeJ2ME source: ${FREEJ2ME_REPO}"
    echo "mobile-support: ${MOBILE_SUPPORT_URL}"
    echo
    echo "OpenJDK JDK image: ${RUNTIME_ROOT}/jdk"
    echo "OpenJDK static libs: ${RUNTIME_ROOT}/lib"
    echo "JNI headers: ${RUNTIME_ROOT}/include"
    echo "FreeJ2ME core JAR: ${FREEJ2ME_JAR}"
    echo "Generated xcconfig: ${XCCONFIG}"
    echo
    echo "CUPS include root: ${CUPS_INCLUDE}"
    echo "CUPS header: ${CUPS_HEADER}"
    echo "libffi include: ${LIBFFI_INCLUDE}"
    echo "libffi libs: ${LIBFFI_LIB}"
    echo
    echo "Static archives:"
    for archive in "${STATIC_ARCHIVES[@]}"; do
        echo "  ${archive}"
    done
} > "${MANIFEST}"

log "Runtime preparation completed successfully."
log "Runtime root: ${RUNTIME_ROOT}"
log "JDK image:    ${RUNTIME_ROOT}/jdk"
log "Static libs:  ${RUNTIME_ROOT}/lib"
log "JNI include:  ${RUNTIME_ROOT}/include"
log "FreeJ2ME JAR: ${FREEJ2ME_JAR}"
log "xcconfig:     ${XCCONFIG}"
log "manifest:     ${MANIFEST}"
