#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_ROOT="${ROOT}/build/ios-runtime-work"
OUT_ROOT="${ROOT}/build/ios-runtime"

OJDK_ROOT="${BUILD_ROOT}/openjdk-mobile"
SUPPORT_ZIP="${BUILD_ROOT}/mobile-support.zip"
SUPPORT_ROOT="${BUILD_ROOT}/support"

FREEJ2ME_ROOT="${BUILD_ROOT}/freej2me"
FREEJ2ME_CLASSES="${BUILD_ROOT}/freej2me-classes"

BOOTSTRAP_ROOT="${ROOT}/JavaOne/Features/Emulator/Runtime/EmbeddedJVM/Bootstrap"

BUILD_CONF="ios-aarch64-zero-release"

mkdir -p "${BUILD_ROOT}"
rm -rf "${OUT_ROOT}"
mkdir -p "${OUT_ROOT}/lib" "${OUT_ROOT}/include" "${OUT_ROOT}/jdk"

log() {
    echo
    echo "============================================================"
    echo "[CoreJ2 runtime] $*"
    echo "============================================================"
}

fail() {
    echo "[CoreJ2 runtime] ERROR: $*" >&2
    exit 1
}

# ------------------------------------------------------------
# Host tools
# ------------------------------------------------------------

for tool in git curl unzip rsync xcrun; do
    command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is required."
done

if ! command -v autoconf >/dev/null 2>&1; then
    command -v brew >/dev/null 2>&1 || fail "autoconf is missing and Homebrew is unavailable."
    brew install autoconf
fi

if ! command -v ant >/dev/null 2>&1; then
    command -v brew >/dev/null 2>&1 || fail "ant is missing and Homebrew is unavailable."
    brew install ant
fi

# ------------------------------------------------------------
# Boot JDK
# ------------------------------------------------------------
# The current OpenJDK Mobile checkout used by this workflow reports
# that its Boot JDK must be 26, 27, or 28.

JAVA_HOME="${JAVA_HOME:-}"

if [[ -z "${JAVA_HOME}" ]]; then
    JAVA_HOME="$(/usr/libexec/java_home -v 26 2>/dev/null || true)"
fi

[[ -n "${JAVA_HOME}" ]] || fail "JDK 26/27/28 was not found."

[[ -x "${JAVA_HOME}/bin/java" && -x "${JAVA_HOME}/bin/javac" ]] || \
    fail "JAVA_HOME does not contain java/javac: ${JAVA_HOME}"

export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"

JAVA_VERSION="$("${JAVA_HOME}/bin/java" -version 2>&1 | head -n 1)"
JAVA_MAJOR="$("${JAVA_HOME}/bin/java" -version 2>&1 | sed -nE 's/.*version "([0-9]+).*/\1/p')"

log "Boot JDK: ${JAVA_HOME}"
log "Java: ${JAVA_VERSION}"

case "${JAVA_MAJOR}" in
    26|27|28)
        ;;
    *)
        fail "Boot JDK ${JAVA_MAJOR} is unsupported. Required: 26, 27, or 28."
        ;;
esac

# ------------------------------------------------------------
# OpenJDK Mobile
# ------------------------------------------------------------

if [[ ! -d "${OJDK_ROOT}/.git" ]]; then
    log "Cloning OpenJDK Mobile"
    git clone --depth 1 https://github.com/openjdk/mobile.git "${OJDK_ROOT}"
else
    log "OpenJDK Mobile checkout already exists"
fi

# ------------------------------------------------------------
# Gluon mobile support
# ------------------------------------------------------------

if [[ ! -f "${SUPPORT_ZIP}" ]]; then
    log "Downloading mobile-support-20250106.zip"
    curl -fL --retry 4 --retry-delay 2 \
        -o "${SUPPORT_ZIP}" \
        https://download2.gluonhq.com/mobile/mobile-support-20250106.zip
fi

rm -rf "${SUPPORT_ROOT}"
mkdir -p "${SUPPORT_ROOT}"

log "Extracting mobile-support"
unzip -q "${SUPPORT_ZIP}" -d "${SUPPORT_ROOT}"

# ------------------------------------------------------------
# Locate libffi
# ------------------------------------------------------------

LIBFFI_INCLUDE=""
LIBFFI_LIB=""

if [[ -f "${SUPPORT_ROOT}/libffi/include/ffi.h" ]]; then
    LIBFFI_INCLUDE="${SUPPORT_ROOT}/libffi/include"
fi

if [[ -d "${SUPPORT_ROOT}/libffi/libs" ]]; then
    LIBFFI_LIB="${SUPPORT_ROOT}/libffi/libs"
elif [[ -d "${SUPPORT_ROOT}/libffi/lib" ]]; then
    LIBFFI_LIB="${SUPPORT_ROOT}/libffi/lib"
fi

if [[ -z "${LIBFFI_INCLUDE}" ]]; then
    LIBFFI_HEADER="$(find "${SUPPORT_ROOT}" -type f -name ffi.h -path '*/include/*' -print -quit 2>/dev/null || true)"
    if [[ -n "${LIBFFI_HEADER}" ]]; then
        LIBFFI_INCLUDE="$(dirname "${LIBFFI_HEADER}")"
    fi
fi

if [[ -z "${LIBFFI_LIB}" ]]; then
    LIBFFI_ARCHIVE="$(find "${SUPPORT_ROOT}" -type f \( -name 'libffi.a' -o -name 'libffi.dylib' \) -print -quit 2>/dev/null || true)"
    if [[ -n "${LIBFFI_ARCHIVE}" ]]; then
        LIBFFI_LIB="$(dirname "${LIBFFI_ARCHIVE}")"
    fi
fi

[[ -n "${LIBFFI_INCLUDE}" && -d "${LIBFFI_INCLUDE}" ]] || \
    fail "Could not locate libffi include directory under ${SUPPORT_ROOT}"

[[ -n "${LIBFFI_LIB}" && -d "${LIBFFI_LIB}" ]] || \
    fail "Could not locate libffi library directory under ${SUPPORT_ROOT}"

log "libffi include: ${LIBFFI_INCLUDE}"
log "libffi lib:     ${LIBFFI_LIB}"

# ------------------------------------------------------------
# Locate CUPS
# ------------------------------------------------------------
# IMPORTANT:
# OpenJDK configure expects --with-cups=<ROOT>, where:
#   <ROOT>/include/cups/cups.h
#
# Do not use --with-cups=none. "none" is interpreted as a path.

CUPS_ROOT=""

CUPS_HEADER="$(find "${SUPPORT_ROOT}" \
    -type f \
    -path '*/include/cups/cups.h' \
    -print -quit 2>/dev/null || true)"

if [[ -n "${CUPS_HEADER}" ]]; then
    CUPS_ROOT="$(dirname "$(dirname "$(dirname "${CUPS_HEADER}")")")"
fi

if [[ -z "${CUPS_ROOT}" ]]; then
    # Some archives put cups.h directly under a cups include tree.
    CUPS_HEADER="$(find "${SUPPORT_ROOT}" \
        -type f \
        -path '*/cups/cups.h' \
        -print -quit 2>/dev/null || true)"

    if [[ -n "${CUPS_HEADER}" ]]; then
        CUPS_INCLUDE_DIR="$(dirname "${CUPS_HEADER}")"

        # Walk upward until include/cups/cups.h exists.
        candidate="$(dirname "${CUPS_INCLUDE_DIR}")"
        while [[ "${candidate}" != "/" ]]; do
            if [[ -f "${candidate}/include/cups/cups.h" ]]; then
                CUPS_ROOT="${candidate}"
                break
            fi
            candidate="$(dirname "${candidate}")"
        done
    fi
fi

if [[ -z "${CUPS_ROOT}" ]]; then
    echo
    echo "ERROR: CUPS headers were not found in:"
    echo "  ${SUPPORT_ROOT}"
    echo
    echo "Expected:"
    echo "  <cups-root>/include/cups/cups.h"
    echo
    echo "CUPS-related files found:"
    find "${SUPPORT_ROOT}" -type f \( \
        -name 'cups.h' -o \
        -name 'libcups.a' -o \
        -name 'libcups.dylib' \
    \) -print 2>/dev/null | head -50 || true
    echo
    echo "Archive top-level layout:"
    find "${SUPPORT_ROOT}" -maxdepth 3 -type d -print | head -100 || true
    fail "CUPS support files are missing or have an unsupported layout."
fi

[[ -f "${CUPS_ROOT}/include/cups/cups.h" ]] || \
    fail "Detected CUPS root is invalid: ${CUPS_ROOT}"

log "CUPS root: ${CUPS_ROOT}"
log "CUPS header: ${CUPS_ROOT}/include/cups/cups.h"

# ------------------------------------------------------------
# iPhoneOS SDK
# ------------------------------------------------------------

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"

log "iPhoneOS SDK: ${SDK_VERSION}"
log "SDK path: ${SDK_PATH}"

# ------------------------------------------------------------
# Configure OpenJDK Mobile
# ------------------------------------------------------------

cd "${OJDK_ROOT}"

# Always remove a previous configuration. This is important because
# changing dependency paths after a failed configure can otherwise leave
# stale configure values in build/ios-aarch64-zero-release.

if [[ -d "build/${BUILD_CONF}" ]]; then
    log "Removing previous OpenJDK configuration"
    rm -rf "build/${BUILD_CONF}"
fi

log "Configuring OpenJDK Mobile"

bash ./configure \
    --disable-warnings-as-errors \
    --openjdk-target=aarch64-macos-ios \
    --with-boot-jdk="${JAVA_HOME}" \
    --with-libffi-include="${LIBFFI_INCLUDE}" \
    --with-libffi-lib="${LIBFFI_LIB}" \
    --with-cups="${CUPS_ROOT}" \
    --with-sysroot="${SDK_PATH}"

# ------------------------------------------------------------
# Build OpenJDK Mobile
# ------------------------------------------------------------

log "Building OpenJDK Mobile static libraries"

make CONF="${BUILD_CONF}" static-libs-image

log "Building OpenJDK Mobile static JDK image"

make CONF="${BUILD_CONF}" static-jdk-image

STATIC_ROOT="${OJDK_ROOT}/build/${BUILD_CONF}/images/static-libs"
JDK_ROOT="${OJDK_ROOT}/build/${BUILD_CONF}/images/jdk"
LIBJVM="${STATIC_ROOT}/lib/zero/libjvm.a"

[[ -f "${LIBJVM}" ]] || fail "libjvm.a was not produced: ${LIBJVM}"
[[ -d "${JDK_ROOT}" ]] || fail "JDK image was not produced: ${JDK_ROOT}"

# ------------------------------------------------------------
# Copy native runtime
# ------------------------------------------------------------

log "Copying JDK image"

rsync -a --delete \
    "${JDK_ROOT}/" \
    "${OUT_ROOT}/jdk/"

log "Copying static OpenJDK libraries"

rsync -a \
    "${STATIC_ROOT}/lib/" \
    "${OUT_ROOT}/lib/"

JNI_INCLUDE="$(
    find "${OJDK_ROOT}/build/${BUILD_CONF}" \
        -type d \
        -path '*/support/headers/java.base' \
        -print -quit 2>/dev/null || true
)"

if [[ -z "${JNI_INCLUDE}" ]]; then
    JNI_INCLUDE="${OJDK_ROOT}/src/java.base/share/native/include"
fi

[[ -d "${JNI_INCLUDE}" ]] || \
    fail "JNI include directory not found: ${JNI_INCLUDE}"

log "JNI include: ${JNI_INCLUDE}"

cp -R "${JNI_INCLUDE}/." "${OUT_ROOT}/include/"

# ------------------------------------------------------------
# FreeJ2ME
# ------------------------------------------------------------

if [[ ! -d "${FREEJ2ME_ROOT}/.git" ]]; then
    log "Cloning FreeJ2ME"
    git clone --depth 1 https://github.com/hex007/freej2me.git "${FREEJ2ME_ROOT}"
else
    log "FreeJ2ME checkout already exists"
fi

rm -rf "${FREEJ2ME_CLASSES}"
mkdir -p "${FREEJ2ME_CLASSES}"

FREE_SOURCES_LIST="${BUILD_ROOT}/freej2me-sources.txt"

find "${FREEJ2ME_ROOT}/src" \
    -type f \
    -name '*.java' \
    | sort > "${FREE_SOURCES_LIST}"

[[ -d "${BOOTSTRAP_ROOT}" ]] || \
    fail "CoreJ2 bootstrap directory not found: ${BOOTSTRAP_ROOT}"

find "${BOOTSTRAP_ROOT}" \
    -maxdepth 1 \
    -type f \
    -name '*.java' \
    | sort >> "${FREE_SOURCES_LIST}"

[[ -s "${FREE_SOURCES_LIST}" ]] || \
    fail "No FreeJ2ME/CoreJ2 Java source files found."

SOURCE_COUNT="$(wc -l < "${FREE_SOURCES_LIST}" | tr -d ' ')"

log "Compiling FreeJ2ME + CoreJ2 bootstrap"
log "Java source count: ${SOURCE_COUNT}"

"${JAVA_HOME}/bin/javac" \
    -encoding UTF-8 \
    -g:none \
    -source 8 \
    -target 8 \
    -d "${FREEJ2ME_CLASSES}" \
    @"${FREE_SOURCES_LIST}"

FREEJ2ME_JAR="${OUT_ROOT}/freej2me-core.jar"

rm -f "${FREEJ2ME_JAR}"

(
    cd "${FREEJ2ME_CLASSES}"
    "${JAVA_HOME}/bin/jar" cf "${FREEJ2ME_JAR}" .
)

if [[ -d "${FREEJ2ME_ROOT}/resources" ]]; then
    (
        cd "${FREEJ2ME_ROOT}"
        "${JAVA_HOME}/bin/jar" uf "${FREEJ2ME_JAR}" resources
    )
fi

if [[ -d "${FREEJ2ME_ROOT}/META-INF" ]]; then
    (
        cd "${FREEJ2ME_ROOT}"
        "${JAVA_HOME}/bin/jar" uf "${FREEJ2ME_JAR}" META-INF
    )
fi

[[ -f "${FREEJ2ME_JAR}" ]] || \
    fail "freej2me-core.jar was not created."

# ------------------------------------------------------------
# Xcode runtime configuration
# ------------------------------------------------------------

mapfile -t STATIC_LIBS < <(
    find "${OUT_ROOT}/lib" \
        -type f \
        -name '*.a' \
        | sort
)

[[ "${#STATIC_LIBS[@]}" -gt 0 ]] || \
    fail "No OpenJDK static archives found."

STATIC_LDFLAGS=""

for lib in "${STATIC_LIBS[@]}"; do
    STATIC_LDFLAGS+=" \"${lib}\""
done

cat > "${OUT_ROOT}/CoreJ2Runtime.xcconfig" <<CFG
// Generated by scripts/ios-runtime/prepare-runtime.sh

COREJ2_RUNTIME_ROOT = ${OUT_ROOT}

HEADER_SEARCH_PATHS = \$(inherited) "${OUT_ROOT}/include"
LIBRARY_SEARCH_PATHS = \$(inherited) "${OUT_ROOT}/lib"

OTHER_LDFLAGS = \$(inherited)${STATIC_LDFLAGS} -lc++ -lz -liconv
CFG

# ------------------------------------------------------------
# Runtime manifest
# ------------------------------------------------------------

OPENJDK_COMMIT="$(git -C "${OJDK_ROOT}" rev-parse HEAD)"
FREEJ2ME_COMMIT="$(git -C "${FREEJ2ME_ROOT}" rev-parse HEAD)"

LIBJVM_BYTES="$(wc -c < "${LIBJVM}" | tr -d ' ')"
FREEJ2ME_BYTES="$(wc -c < "${FREEJ2ME_JAR}" | tr -d ' ')"

cat > "${OUT_ROOT}/RUNTIME-MANIFEST.txt" <<MANIFEST
CoreJ2 embedded iOS runtime

iPhoneOS SDK:
${SDK_VERSION}

Boot JDK:
${JAVA_VERSION}

OpenJDK Mobile commit:
${OPENJDK_COMMIT}

FreeJ2ME commit:
${FREEJ2ME_COMMIT}

CUPS root:
${CUPS_ROOT}

libjvm.a bytes:
${LIBJVM_BYTES}

freej2me-core.jar bytes:
${FREEJ2ME_BYTES}

Static OpenJDK archives:
${#STATIC_LIBS[@]}

JDK image:
${OUT_ROOT}/jdk

FreeJ2ME/CoreJ2 jar:
${OUT_ROOT}/freej2me-core.jar
MANIFEST

# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

log "Runtime preparation completed"

[[ -f "${OUT_ROOT}/lib/libjvm.a" ]] || \
    fail "Final runtime is missing libjvm.a"

[[ -f "${OUT_ROOT}/freej2me-core.jar" ]] || \
    fail "Final runtime is missing freej2me-core.jar"

[[ -f "${OUT_ROOT}/CoreJ2Runtime.xcconfig" ]] || \
    fail "Final runtime is missing CoreJ2Runtime.xcconfig"

[[ -d "${OUT_ROOT}/jdk" ]] || \
    fail "Final runtime is missing JDK image"

cat "${OUT_ROOT}/RUNTIME-MANIFEST.txt"

echo
echo "Runtime size:"
du -sh "${OUT_ROOT}"

echo
echo "libjvm.a:"
ls -lh "${OUT_ROOT}/lib/libjvm.a"

echo
echo "freej2me-core.jar:"
ls -lh "${OUT_ROOT}/freej2me-core.jar"
