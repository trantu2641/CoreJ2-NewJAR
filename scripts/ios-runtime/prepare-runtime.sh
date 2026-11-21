#!/usr/bin/env bash
set -euo pipefail

# CoreJ2-NewJAR / iOS runtime builder
# Fixed:
#   - no unsupported OpenJDK configure options
#   - no mapfile dependency
#   - works when invoked from GitHub Actions
#   - validates CUPS/libffi layout from mobile-support-20250106.zip

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${ROOT_DIR}/build/ios-runtime-work"
RUNTIME_OUT="${ROOT_DIR}/build/ios-runtime"

OPENJDK_REPO="${OPENJDK_REPO:-https://github.com/openjdk/mobile.git}"
FREEJ2ME_REPO="${FREEJ2ME_REPO:-https://github.com/hex007/freej2me.git}"
OPENJDK_BRANCH="${OPENJDK_BRANCH:-master}"
FREEJ2ME_BRANCH="${FREEJ2ME_BRANCH:-master}"
SUPPORT_URL="${SUPPORT_URL:-https://github.com/openjdk/mobile-support/archive/refs/heads/master.zip}"

mkdir -p "${WORK_DIR}" "${RUNTIME_OUT}"

echo "[CoreJ2 Runtime] ROOT: ${ROOT_DIR}"
echo "[CoreJ2 Runtime] WORK: ${WORK_DIR}"

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

die() {
    echo "::error::$*" >&2
    exit 1
}

log() {
    echo "[CoreJ2 Runtime] $*"
}

find_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# ----------------------------------------------------------------------
# Basic tools
# ----------------------------------------------------------------------

for cmd in git curl unzip find sort sed awk grep xcrun xcodebuild; do
    find_cmd "${cmd}"
done

# Always use bash for this script.
if [[ -z "${BASH_VERSION:-}" ]]; then
    die "prepare-runtime.sh must be executed with bash"
fi

# ----------------------------------------------------------------------
# Xcode / iOS SDK
# ----------------------------------------------------------------------

SDK_PATH="${SDK_PATH:-$(xcrun --sdk iphoneos --show-sdk-path)}"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"

log "iPhoneOS SDK: ${SDK_PATH}"
log "iPhoneOS SDK version: ${SDK_VERSION}"

# ----------------------------------------------------------------------
# Boot JDK
#
# OpenJDK/mobile configure requires a recent boot JDK. Prefer 28, 27,
# then 26. Do not force a specific Xcode/JDK path that may not exist on
# the GitHub Actions runner.
# ----------------------------------------------------------------------

find_boot_jdk() {
    local candidates=(
        "${JAVA_HOME:-}"
        "/Library/Java/JavaVirtualMachines/jdk-28.jdk/Contents/Home"
        "/Library/Java/JavaVirtualMachines/jdk-27.jdk/Contents/Home"
        "/Library/Java/JavaVirtualMachines/jdk-26.jdk/Contents/Home"
        "/Library/Java/JavaVirtualMachines/temurin-28.jdk/Contents/Home"
        "/Library/Java/JavaVirtualMachines/temurin-27.jdk/Contents/Home"
        "/Library/Java/JavaVirtualMachines/temurin-26.jdk/Contents/Home"
    )

    local j
    for j in "${candidates[@]}"; do
        if [[ -n "${j}" && -x "${j}/bin/java" ]]; then
            echo "${j}"
            return 0
        fi
    done

    if command -v java >/dev/null 2>&1; then
        local detected
        detected="$(/usr/libexec/java_home -v 28 2>/dev/null || true)"
        [[ -n "${detected}" && -x "${detected}/bin/java" ]] && { echo "${detected}"; return 0; }

        detected="$(/usr/libexec/java_home -v 27 2>/dev/null || true)"
        [[ -n "${detected}" && -x "${detected}/bin/java" ]] && { echo "${detected}"; return 0; }

        detected="$(/usr/libexec/java_home -v 26 2>/dev/null || true)"
        [[ -n "${detected}" && -x "${detected}/bin/java" ]] && { echo "${detected}"; return 0; }
    fi

    return 1
}

JAVA_HOME="$(find_boot_jdk || true)"
[[ -n "${JAVA_HOME}" ]] || die "Could not find a JDK 26/27/28 boot JDK on this runner."

export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"

log "Boot JDK: ${JAVA_HOME}"
java -version

# ----------------------------------------------------------------------
# Clone OpenJDK Mobile
# ----------------------------------------------------------------------

OPENJDK_DIR="${WORK_DIR}/mobile"

if [[ ! -d "${OPENJDK_DIR}/.git" ]]; then
    log "Cloning OpenJDK Mobile..."
    git clone --depth 1 --branch "${OPENJDK_BRANCH}" "${OPENJDK_REPO}" "${OPENJDK_DIR}"
else
    log "OpenJDK Mobile already exists."
fi

cd "${OPENJDK_DIR}"

if [[ ! -x "${OPENJDK_DIR}/configure" ]]; then
    log "Generating OpenJDK configure script..."
    bash autogen.sh
fi

[[ -x "${OPENJDK_DIR}/configure" ]] || die "OpenJDK configure script was not generated."

# ----------------------------------------------------------------------
# Download / locate mobile-support
# ----------------------------------------------------------------------

SUPPORT_ZIP="${WORK_DIR}/mobile-support.zip"
SUPPORT_ROOT="${WORK_DIR}/support"

if [[ ! -d "${SUPPORT_ROOT}" ]]; then
    log "Downloading mobile-support..."
    curl -L --fail --retry 3 -o "${SUPPORT_ZIP}" "${SUPPORT_URL}"

    mkdir -p "${SUPPORT_ROOT}"
    unzip -q "${SUPPORT_ZIP}" -d "${SUPPORT_ROOT}"
fi

# mobile-support archives can have either:
#   support/<files>
# or:
#   support/support/<files>
# Normalize the root by locating the directory containing libffi/cups.
detect_support_root() {
    local base="${SUPPORT_ROOT}"

    if [[ -d "${base}/support/libffi" || -d "${base}/support/cups-2.3.6" ]]; then
        echo "${base}/support"
        return 0
    fi

    if [[ -d "${base}/support/support/libffi" || -d "${base}/support/support/cups-2.3.6" ]]; then
        echo "${base}/support/support"
        return 0
    fi

    local candidate
    candidate="$(find "${base}" -type d -name libffi -print -quit 2>/dev/null || true)"
    if [[ -n "${candidate}" ]]; then
        echo "$(dirname "${candidate}")"
        return 0
    fi

    return 1
}

SUPPORT_NATIVE_ROOT="$(detect_support_root || true)"
[[ -n "${SUPPORT_NATIVE_ROOT}" ]] || die "Could not locate mobile-support root."

log "Support root: ${SUPPORT_NATIVE_ROOT}"

# ----------------------------------------------------------------------
# libffi
# ----------------------------------------------------------------------

LIBFFI_ROOT="${SUPPORT_NATIVE_ROOT}/libffi"

if [[ ! -d "${LIBFFI_ROOT}" ]]; then
    LIBFFI_ROOT="$(find "${SUPPORT_NATIVE_ROOT}" -type d -name libffi -print -quit 2>/dev/null || true)"
fi

[[ -n "${LIBFFI_ROOT}" && -d "${LIBFFI_ROOT}" ]] || die "libffi directory not found."

LIBFFI_INCLUDE="${LIBFFI_ROOT}/include"
LIBFFI_LIB="${LIBFFI_ROOT}/lib"

[[ -d "${LIBFFI_INCLUDE}" ]] || die "libffi include directory not found: ${LIBFFI_INCLUDE}"
[[ -d "${LIBFFI_LIB}" ]] || die "libffi lib directory not found: ${LIBFFI_LIB}"

# ----------------------------------------------------------------------
# CUPS
#
# The mobile-support archive currently contains:
#   support/support/cups-2.3.6/cups/cups.h
#
# --with-cups-include must point to the directory containing the
# cups/ subdirectory, NOT directly to cups/.
# ----------------------------------------------------------------------

CUPS_INCLUDE="${SUPPORT_NATIVE_ROOT}/cups-2.3.6"

if [[ ! -f "${CUPS_INCLUDE}/cups/cups.h" ]]; then
    CUPS_INCLUDE="$(find "${SUPPORT_NATIVE_ROOT}" -type f -path '*/cups/cups.h' -print -quit 2>/dev/null | xargs -r dirname | xargs -r dirname || true)"
fi

[[ -n "${CUPS_INCLUDE}" ]] || die "Could not locate cups/cups.h."
[[ -f "${CUPS_INCLUDE}/cups/cups.h" ]] || die "CUPS header validated path does not exist: ${CUPS_INCLUDE}/cups/cups.h"

log "CUPS header validated: ${CUPS_INCLUDE}/cups/cups.h"

# ----------------------------------------------------------------------
# Configure
# ----------------------------------------------------------------------

BUILD_CONF="${OPENJDK_DIR}/build/ios-aarch64-zero-release"

rm -rf "${BUILD_CONF}"

log "Configuring OpenJDK Mobile..."

# IMPORTANT:
# Do NOT add:
#   --disable-manpages
#   --disable-jvm-feature-serviceability-agent
#
# The OpenJDK/mobile configure script used by this build does not accept
# those options. The previous build reached configure and failed only
# because of them.
#
# Also do not use mapfile anywhere in this script: GitHub's macOS shell
# environment can invoke scripts in a way where that bash builtin is not
# available.

bash "${OPENJDK_DIR}/configure" \
    --disable-warnings-as-errors \
    --openjdk-target=aarch64-macos-ios \
    --with-boot-jdk="${JAVA_HOME}" \
    --with-libffi-include="${LIBFFI_INCLUDE}" \
    --with-libffi-lib="${LIBFFI_LIB}" \
    --with-cups-include="${CUPS_INCLUDE}" \
    --with-sysroot="${SDK_PATH}" \
    --with-debug-level=release \
    --with-native-debug-symbols=none \
    --with-jvm-variants=zero

# ----------------------------------------------------------------------
# Build static runtime
# ----------------------------------------------------------------------

cd "${OPENJDK_DIR}"

log "Building static-libs-image..."

make JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}" \
    images \
    static-libs-image \
    LOG=info

# Some OpenJDK/mobile revisions do not expose the same exact make target
# layout. Verify the important output rather than silently continuing.
STATIC_IMAGE="${BUILD_CONF}/images/jdk"
STATIC_LIB_DIR="${BUILD_CONF}/support/modules_libs"

if [[ ! -d "${STATIC_IMAGE}" && ! -d "${STATIC_LIB_DIR}" ]]; then
    die "OpenJDK static runtime output was not found after static-libs-image."
fi

log "OpenJDK static-libs-image completed."

# ----------------------------------------------------------------------
# Build static JDK image when supported
# ----------------------------------------------------------------------

if make help 2>/dev/null | grep -q "static-jdk-image"; then
    log "Building static-jdk-image..."
    make JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}" \
        static-jdk-image \
        LOG=info || {
            log "static-jdk-image target failed; continuing with static-libs-image."
        }
fi

# ----------------------------------------------------------------------
# FreeJ2ME
# ----------------------------------------------------------------------

FREEJ2ME_DIR="${WORK_DIR}/freej2me"

if [[ ! -d "${FREEJ2ME_DIR}/.git" ]]; then
    log "Cloning FreeJ2ME..."
    git clone --depth 1 --branch "${FREEJ2ME_BRANCH}" "${FREEJ2ME_REPO}" "${FREEJ2ME_DIR}"
else
    log "FreeJ2ME already exists."
fi

# ----------------------------------------------------------------------
# Locate FreeJ2ME jars WITHOUT mapfile
# ----------------------------------------------------------------------

FREEJ2ME_JARS=()

while IFS= read -r jar_file; do
    [[ -n "${jar_file}" ]] && FREEJ2ME_JARS+=("${jar_file}")
done < <(
    find "${FREEJ2ME_DIR}" \
        -type f \
        \( -name "*.jar" -o -name "*.JAR" \) \
        -print 2>/dev/null | sort
)

log "Found ${#FREEJ2ME_JARS[@]} FreeJ2ME JAR file(s)."

# ----------------------------------------------------------------------
# Build FreeJ2ME core when Maven/Gradle project is available
# ----------------------------------------------------------------------

FREEJ2ME_CORE_JAR=""

if [[ -f "${FREEJ2ME_DIR}/pom.xml" ]]; then
    if command -v mvn >/dev/null 2>&1; then
        log "Building FreeJ2ME with Maven..."
        (
            cd "${FREEJ2ME_DIR}"
            mvn -B -DskipTests package
        ) || log "FreeJ2ME Maven build failed; using existing JARs."
    else
        log "Maven not installed; skipping FreeJ2ME Maven build."
    fi
fi

# Find a likely core JAR after the build.
while IFS= read -r jar_file; do
    if [[ -z "${FREEJ2ME_CORE_JAR}" ]]; then
        case "$(basename "${jar_file}")" in
            *freej2me*core*.jar|*freej2me-core*.jar|freej2me.jar)
                FREEJ2ME_CORE_JAR="${jar_file}"
                ;;
        esac
    fi
done < <(
    find "${FREEJ2ME_DIR}" \
        -type f \
        \( -name "*.jar" -o -name "*.JAR" \) \
        -print 2>/dev/null | sort
)

# ----------------------------------------------------------------------
# Collect runtime artifacts
# ----------------------------------------------------------------------

rm -rf "${RUNTIME_OUT}"
mkdir -p "${RUNTIME_OUT}/jdk" \
         "${RUNTIME_OUT}/lib" \
         "${RUNTIME_OUT}/include" \
         "${RUNTIME_OUT}/freej2me"

copy_if_exists() {
    local src="$1"
    local dst="$2"

    if [[ -e "${src}" ]]; then
        mkdir -p "$(dirname "${dst}")"
        cp -R "${src}" "${dst}"
        return 0
    fi

    return 1
}

# JDK image
if [[ -d "${STATIC_IMAGE}" ]]; then
    copy_if_exists "${STATIC_IMAGE}" "${RUNTIME_OUT}/jdk"
fi

# Static native libraries
if [[ -d "${STATIC_LIB_DIR}" ]]; then
    copy_if_exists "${STATIC_LIB_DIR}" "${RUNTIME_OUT}/lib/modules_libs"
fi

# JNI headers
JNI_INCLUDE="${OPENJDK_DIR}/src/java.base/share/native/include"
if [[ -d "${JNI_INCLUDE}" ]]; then
    cp -R "${JNI_INCLUDE}/." "${RUNTIME_OUT}/include/"
fi

# FreeJ2ME jars
while IFS= read -r jar_file; do
    [[ -z "${jar_file}" ]] && continue
    cp "${jar_file}" "${RUNTIME_OUT}/freej2me/"
done < <(
    find "${FREEJ2ME_DIR}" \
        -type f \
        \( -name "*.jar" -o -name "*.JAR" \) \
        -print 2>/dev/null | sort
)

# Prefer the discovered core jar as the canonical name.
if [[ -n "${FREEJ2ME_CORE_JAR}" && -f "${FREEJ2ME_CORE_JAR}" ]]; then
    cp "${FREEJ2ME_CORE_JAR}" "${RUNTIME_OUT}/freej2me/freej2me-core.jar"
fi

# ----------------------------------------------------------------------
# Generate xcconfig for the Swift/Xcode target
# ----------------------------------------------------------------------

cat > "${RUNTIME_OUT}/CoreJ2Runtime.xcconfig" <<EOF
// Generated by scripts/ios-runtime/prepare-runtime.sh

COREJ2_RUNTIME_ROOT = \$(SRCROOT)/build/ios-runtime
COREJ2_RUNTIME_JDK = \$(COREJ2_RUNTIME_ROOT)/jdk
COREJ2_RUNTIME_LIB = \$(COREJ2_RUNTIME_ROOT)/lib
COREJ2_RUNTIME_INCLUDE = \$(COREJ2_RUNTIME_ROOT)/include
COREJ2_FREEJ2ME = \$(COREJ2_RUNTIME_ROOT)/freej2me

HEADER_SEARCH_PATHS = \$(inherited) \$(COREJ2_RUNTIME_INCLUDE)
LIBRARY_SEARCH_PATHS = \$(inherited) \$(COREJ2_RUNTIME_LIB)
EOF

# ----------------------------------------------------------------------
# Manifest
# ----------------------------------------------------------------------

cat > "${RUNTIME_OUT}/RUNTIME-MANIFEST.txt" <<EOF
CoreJ2-NewJAR iOS Runtime
=========================

OpenJDK source:
  ${OPENJDK_REPO}

OpenJDK branch:
  ${OPENJDK_BRANCH}

FreeJ2ME source:
  ${FREEJ2ME_REPO}

FreeJ2ME branch:
  ${FREEJ2ME_BRANCH}

iPhoneOS SDK:
  ${SDK_PATH}

iPhoneOS SDK version:
  ${SDK_VERSION}

Boot JDK:
  ${JAVA_HOME}

CUPS include:
  ${CUPS_INCLUDE}

libffi include:
  ${LIBFFI_INCLUDE}

libffi lib:
  ${LIBFFI_LIB}

FreeJ2ME JAR count:
  ${#FREEJ2ME_JARS[@]}
EOF

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------

log "Runtime preparation completed successfully."
log "Output: ${RUNTIME_OUT}"

echo
echo "=== CoreJ2 Runtime Artifacts ==="
find "${RUNTIME_OUT}" -maxdepth 2 -type f -print | sort || true
echo
echo "=== Runtime Size ==="
du -sh "${RUNTIME_OUT}" 2>/dev/null || true
echo
echo "[CoreJ2 Runtime] DONE"
