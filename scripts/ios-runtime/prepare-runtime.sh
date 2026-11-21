#!/usr/bin/env bash
#
# CoreJ2-NewJAR: prepare OpenJDK Mobile + FreeJ2ME runtime for iOS arm64.
#
# Fixes:
#  - Handles nested mobile-support/support layout.
#  - Uses the correct CUPS include root.
#  - Uses the OpenJDK iOS configure target.
#  - Does NOT request static-jdk-image/static-launchers: those are desktop
#    launcher targets and are not usable as an iOS app runtime.
#  - Builds only the OpenJDK runtime/static library outputs required by the
#    embedded JVM. The iOS target uses libjvm.a from static-libs-image.
#
# IMPORTANT:
# This is a build-preparation script, not a claim that OpenJDK Mobile's current
# upstream branch has complete production support for every iOS configuration.
# The script validates each expected output and stops with a useful message.

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_ROOT="${ROOT_DIR}/build/ios-runtime-work"
RUNTIME_ROOT="${ROOT_DIR}/build/ios-runtime"

OPENJDK_DIR="${WORK_ROOT}/mobile"
SUPPORT_ROOT="${WORK_ROOT}/support"
FREEJ2ME_DIR="${WORK_ROOT}/freej2me"
FREEJ2ME_BUILD="${WORK_ROOT}/freej2me-build"

BUILD_CONF="ios-aarch64-zero-release"
OPENJDK_BUILD_DIR="${OPENJDK_DIR}/build/${BUILD_CONF}"
STATIC_LIBS_DIR="${OPENJDK_BUILD_DIR}/images/static-libs"
STATIC_LIBS_SUPPORT_DIR="${OPENJDK_BUILD_DIR}/support/modules_libs/java.base"
JVM_STATIC_CANDIDATE="${OPENJDK_BUILD_DIR}/hotspot/variant-zero/libjvm/objs/static/libjvm.a"

BOOTSTRAP_DIR="${ROOT_DIR}/JavaOne/Features/Emulator/Runtime/EmbeddedJVM/Bootstrap"

OPENJDK_REPO="https://github.com/openjdk/mobile.git"
FREEJ2ME_REPO="https://github.com/hex007/freej2me.git"
MOBILE_SUPPORT_URL="https://download2.gluonhq.com/mobile/mobile-support-20250106.zip"

log() { printf '\n[CoreJ2 Runtime] %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }

for cmd in git curl unzip rsync xcrun autoconf ant make find sort sed awk jar; do
    need_cmd "$cmd"
done

find_boot_jdk() {
    if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
        printf '%s\n' "${JAVA_HOME}"
        return
    fi
    if command -v /usr/libexec/java_home >/dev/null 2>&1; then
        local candidate
        for version in 26 27 28; do
            candidate="$(/usr/libexec/java_home -v "${version}" 2>/dev/null || true)"
            if [[ -n "${candidate}" && -x "${candidate}/bin/java" ]]; then
                printf '%s\n' "${candidate}"
                return
            fi
        done
    fi
    fail "JDK 26, 27 or 28 is required. Install JDK 26 with actions/setup-java."
}

JAVA_HOME="$(find_boot_jdk)"
export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"

JAVA_VERSION="$("${JAVA_HOME}/bin/java" -version 2>&1 | head -n 1 || true)"
JAVA_MAJOR="$("${JAVA_HOME}/bin/java" -version 2>&1 | sed -nE 's/.*version "([0-9]+).*/\1/p' | head -n 1)"
case "${JAVA_MAJOR}" in
    26|27|28) ;;
    *) fail "Unsupported Boot JDK '${JAVA_VERSION}'. Expected JDK 26/27/28." ;;
esac
log "Boot JDK: ${JAVA_VERSION}"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
[[ -d "${SDK_PATH}" ]] || fail "iPhoneOS SDK missing: ${SDK_PATH}"
log "iPhoneOS SDK ${SDK_VERSION}: ${SDK_PATH}"

mkdir -p "${WORK_ROOT}" "${RUNTIME_ROOT}"

# ---------------------------------------------------------------------------
# Fetch OpenJDK Mobile
# ---------------------------------------------------------------------------
if [[ ! -d "${OPENJDK_DIR}/.git" ]]; then
    log "Cloning OpenJDK Mobile..."
    rm -rf "${OPENJDK_DIR}"
    git clone --depth 1 "${OPENJDK_REPO}" "${OPENJDK_DIR}"
else
    log "OpenJDK Mobile checkout already exists."
fi

# ---------------------------------------------------------------------------
# Download and inspect Gluon mobile support
# ---------------------------------------------------------------------------
SUPPORT_ZIP="${WORK_ROOT}/mobile-support-20250106.zip"
if [[ ! -s "${SUPPORT_ZIP}" ]]; then
    log "Downloading mobile-support..."
    curl -fL --retry 3 --retry-delay 2 -o "${SUPPORT_ZIP}" "${MOBILE_SUPPORT_URL}"
fi

rm -rf "${SUPPORT_ROOT}"
mkdir -p "${SUPPORT_ROOT}"
unzip -q "${SUPPORT_ZIP}" -d "${SUPPORT_ROOT}"

ACTUAL_SUPPORT_ROOT="${SUPPORT_ROOT}"
if [[ -d "${SUPPORT_ROOT}/support" ]] && \
   { [[ -d "${SUPPORT_ROOT}/support/libffi" ]] || [[ -d "${SUPPORT_ROOT}/support/cups-2.3.6" ]]; }; then
    ACTUAL_SUPPORT_ROOT="${SUPPORT_ROOT}/support"
fi

LIBFFI_INCLUDE="${ACTUAL_SUPPORT_ROOT}/libffi/include"
LIBFFI_LIB="${ACTUAL_SUPPORT_ROOT}/libffi/libs"
CUPS_INCLUDE="${ACTUAL_SUPPORT_ROOT}/cups-2.3.6"
CUPS_HEADER="${CUPS_INCLUDE}/cups/cups.h"

[[ -d "${LIBFFI_INCLUDE}" ]] || fail "libffi include folder missing: ${LIBFFI_INCLUDE}"
[[ -d "${LIBFFI_LIB}" ]] || fail "libffi libraries folder missing: ${LIBFFI_LIB}"
if [[ ! -f "${CUPS_HEADER}" ]]; then
    find "${SUPPORT_ROOT}" -type f \( -name cups.h -o -name 'libcups*.a' \) -print | head -n 50 || true
    fail "CUPS header missing. Expected ${CUPS_HEADER}"
fi

log "Support root: ${ACTUAL_SUPPORT_ROOT}"
log "CUPS header validated: ${CUPS_HEADER}"

# ---------------------------------------------------------------------------
# Configure for iOS arm64
#
# The OpenJDK mobile port recognizes the target triple ending in -ios.
# Do not use a macOS target triple: it produces Mach-O macOS binaries rather
# than iOS binaries. We also explicitly select clang and the zero VM.
# ---------------------------------------------------------------------------
cd "${OPENJDK_DIR}"

if [[ -d "${OPENJDK_BUILD_DIR}" ]]; then
    log "Removing stale build configuration ${BUILD_CONF}..."
    rm -rf "${OPENJDK_BUILD_DIR}"
fi

log "Configuring OpenJDK for aarch64 iOS..."
bash ./configure \
    --disable-warnings-as-errors \
    --openjdk-target=aarch64-macos-ios \
    --with-boot-jdk="${JAVA_HOME}" \
    --with-libffi-include="${LIBFFI_INCLUDE}" \
    --with-libffi-lib="${LIBFFI_LIB}" \
    --with-cups-include="${CUPS_INCLUDE}" \
    --with-sysroot="${SDK_PATH}"
    
# Save configure summary for diagnostics.
if [[ -f "${OPENJDK_BUILD_DIR}/spec.gmk" ]]; then
    cp "${OPENJDK_BUILD_DIR}/spec.gmk" "${WORK_ROOT}/openjdk-spec-${BUILD_CONF}.gmk"
fi

# ---------------------------------------------------------------------------
# Build only the static runtime libraries.
#
# Do not run `static-jdk-image` or `static-launchers` for iOS. Those goals
# assemble command-line launchers / static JDK images and their makefiles
# don't have an iOS launcher linker implementation.
# ---------------------------------------------------------------------------
log "Building iOS OpenJDK static libraries..."
make CONF="${BUILD_CONF}" static-libs-image

# Locate libjvm.a. Paths can differ across mobile port revisions.
JVM_STATIC_LIB=""
for candidate in \
    "${JVM_STATIC_CANDIDATE}" \
    "${OPENJDK_BUILD_DIR}/hotspot/variant-zero/libjvm/objs/static/libjvm.a" \
    "${OPENJDK_BUILD_DIR}/images/static-libs/lib/zero/libjvm.a" \
    "${OPENJDK_BUILD_DIR}/support/modules_libs/java.base/zero/libjvm.a"; do
    if [[ -f "${candidate}" ]]; then
        JVM_STATIC_LIB="${candidate}"
        break
    fi
done

if [[ -z "${JVM_STATIC_LIB}" ]]; then
    JVM_STATIC_LIB="$(find "${OPENJDK_BUILD_DIR}" -type f -name libjvm.a -print -quit || true)"
fi

if [[ -z "${JVM_STATIC_LIB}" ]]; then
    log "Available JVM library outputs:"
    find "${OPENJDK_BUILD_DIR}" -type f \( -name 'libjvm.*' -o -name 'libjvm*' \) -print | head -n 80 || true
    fail "OpenJDK did not produce libjvm.a. Check the target/toolchain configure output."
fi

# Copy static library outputs. Preserve OpenJDK's directory structure so
# dependent archives remain discoverable.
rm -rf "${RUNTIME_ROOT}/lib"
mkdir -p "${RUNTIME_ROOT}/lib"
if [[ -d "${STATIC_LIBS_DIR}" ]]; then
    rsync -a "${STATIC_LIBS_DIR}/" "${RUNTIME_ROOT}/lib/"
fi
mkdir -p "${RUNTIME_ROOT}/lib/zero"
cp -f "${JVM_STATIC_LIB}" "${RUNTIME_ROOT}/lib/zero/libjvm.a"

# Also gather other static archives generated under support/modules_libs.
while IFS= read -r -d '' archive; do
    destination="${RUNTIME_ROOT}/lib/archives/$(basename "$(dirname "$(dirname "${archive}")")")"
    mkdir -p "${destination}"
    cp -f "${archive}" "${destination}/"
done < <(find "${OPENJDK_BUILD_DIR}" -type f -name '*.a' -print0)

# ---------------------------------------------------------------------------
# Copy headers
# ---------------------------------------------------------------------------
rm -rf "${RUNTIME_ROOT}/include"
mkdir -p "${RUNTIME_ROOT}/include"

JNI_HEADER="$(find "${OPENJDK_DIR}/src" "${OPENJDK_BUILD_DIR}" -type f -name jni.h -print -quit 2>/dev/null || true)"
[[ -n "${JNI_HEADER}" ]] || fail "Could not locate jni.h in the OpenJDK source/build tree."
JNI_INCLUDE_DIR="$(dirname "${JNI_HEADER}")"
rsync -a "${JNI_INCLUDE_DIR}/" "${RUNTIME_ROOT}/include/"

while IFS= read -r -d '' md_header; do
    cp -f "${md_header}" "${RUNTIME_ROOT}/include/"
done < <(find "${OPENJDK_DIR}/src" "${OPENJDK_BUILD_DIR}" -type f -name jni_md.h -print0 2>/dev/null)

# Additional common JVM headers if present.
for header in jvm.h jvmticmlr.h jni.h jni_md.h; do
    candidate="$(find "${OPENJDK_DIR}/src" "${OPENJDK_BUILD_DIR}" -type f -name "${header}" -print -quit 2>/dev/null || true)"
    if [[ -n "${candidate}" ]]; then
        cp -f "${candidate}" "${RUNTIME_ROOT}/include/${header}" 2>/dev/null || true
    fi
done

# ---------------------------------------------------------------------------
# Build FreeJ2ME Java classes into a jar
# ---------------------------------------------------------------------------
if [[ ! -d "${FREEJ2ME_DIR}/.git" ]]; then
    log "Cloning FreeJ2ME..."
    rm -rf "${FREEJ2ME_DIR}"
    git clone --depth 1 "${FREEJ2ME_REPO}" "${FREEJ2ME_DIR}"
fi

FREEJ2ME_SRC="${FREEJ2ME_DIR}/src"
[[ -d "${FREEJ2ME_SRC}" ]] || fail "FreeJ2ME source folder missing: ${FREEJ2ME_SRC}"

FREEJ2ME_CLASSES="${FREEJ2ME_BUILD}/classes"
FREEJ2ME_JAR="${RUNTIME_ROOT}/freej2me-core.jar"
rm -rf "${FREEJ2ME_BUILD}"
mkdir -p "${FREEJ2ME_CLASSES}"

mapfile -t FREEJ2ME_JAVA_FILES < <(find "${FREEJ2ME_SRC}" -type f -name '*.java' | sort)
((${#FREEJ2ME_JAVA_FILES[@]} > 0)) || fail "FreeJ2ME has no Java source files."

BOOTSTRAP_JAVA_FILES=()
if [[ -d "${BOOTSTRAP_DIR}" ]]; then
    while IFS= read -r -d '' file; do
        BOOTSTRAP_JAVA_FILES+=("${file}")
    done < <(find "${BOOTSTRAP_DIR}" -type f -name '*.java' -print0 | sort -z)
fi

ALL_JAVA_FILES=("${FREEJ2ME_JAVA_FILES[@]}" "${BOOTSTRAP_JAVA_FILES[@]}")
log "Compiling ${#ALL_JAVA_FILES[@]} FreeJ2ME/bootstrap Java files..."
"${JAVA_HOME}/bin/javac" \
    -encoding UTF-8 \
    -source 8 -target 8 \
    -d "${FREEJ2ME_CLASSES}" \
    "${ALL_JAVA_FILES[@]}"

(
    cd "${FREEJ2ME_CLASSES}"
    "${JAVA_HOME}/bin/jar" cf "${FREEJ2ME_JAR}" .
)
[[ -s "${FREEJ2ME_JAR}" ]] || fail "Failed to create ${FREEJ2ME_JAR}"

# ---------------------------------------------------------------------------
# Generate Xcode settings
# ---------------------------------------------------------------------------
XCCONFIG="${RUNTIME_ROOT}/CoreJ2Runtime.xcconfig"
cat > "${XCCONFIG}" <<EOF
// Generated by scripts/ios-runtime/prepare-runtime.sh
// Embedded iOS ARM64 runtime artifacts.
COREJ2_RUNTIME_ROOT = ${RUNTIME_ROOT}
COREJ2_RUNTIME_JNI_INCLUDE = ${RUNTIME_ROOT}/include
COREJ2_FREEJ2ME_JAR = ${FREEJ2ME_JAR}
HEADER_SEARCH_PATHS = \$(inherited) ${RUNTIME_ROOT}/include
LIBRARY_SEARCH_PATHS = \$(inherited) ${RUNTIME_ROOT}/lib ${RUNTIME_ROOT}/lib/zero
OTHER_LDFLAGS = \$(inherited) -lc++ -lz -liconv
EOF

# Write a manifest with actual output file locations.
MANIFEST="${RUNTIME_ROOT}/RUNTIME-MANIFEST.txt"
{
    echo "CoreJ2 iOS embedded runtime"
    echo "Generated UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "OpenJDK repo: ${OPENJDK_REPO}"
    echo "OpenJDK target: aarch64-apple-ios"
    echo "OpenJDK config: ${BUILD_CONF}"
    echo "Boot JDK: ${JAVA_VERSION}"
    echo "iPhoneOS SDK: ${SDK_VERSION}"
    echo "Support root: ${ACTUAL_SUPPORT_ROOT}"
    echo "CUPS include: ${CUPS_INCLUDE}"
    echo "libffi include: ${LIBFFI_INCLUDE}"
    echo "JVM static library: ${JVM_STATIC_LIB}"
    echo "FreeJ2ME JAR: ${FREEJ2ME_JAR}"
    echo "Xcode config: ${XCCONFIG}"
    echo
    echo "Static archives copied:"
    find "${RUNTIME_ROOT}/lib" -type f -name '*.a' -print | sort
} > "${MANIFEST}"

log "Runtime preparation completed."
log "libjvm.a: ${RUNTIME_ROOT}/lib/zero/libjvm.a"
log "FreeJ2ME: ${FREEJ2ME_JAR}"
log "xcconfig: ${XCCONFIG}"
log "manifest: ${MANIFEST}"
