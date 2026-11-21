#!/usr/bin/env bash
set -euo pipefail

# CoreJ2 / iOS runtime preparation
# Fixes:
# - macOS 26 / Xcode 26.x runners
# - nested mobile-support/support layout
# - CUPS include path
# - removed unsupported configure flags
# - OpenJDK configure bootstrap: configure/autogen.sh/make/autoconf/autoreconf
# - executable prepare script permissions

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
WORK_DIR="${ROOT_DIR}/build/ios-runtime-work"
OPENJDK_DIR="${WORK_DIR}/openjdk-mobile"
FREEJ2ME_DIR="${WORK_DIR}/freej2me"
SUPPORT_DIR="${WORK_DIR}/support"
RUNTIME_OUT="${ROOT_DIR}/build/ios-runtime"

OPENJDK_REPO="${OPENJDK_REPO:-https://github.com/openjdk/mobile.git}"
FREEJ2ME_REPO="${FREEJ2ME_REPO:-https://github.com/hex007/freej2me.git}"

die() {
    echo "::error::$*" >&2
    exit 1
}

log() {
    echo "[CoreJ2 Runtime] $*"
}

command -v git >/dev/null 2>&1 || die "git is not installed."
command -v xcrun >/dev/null 2>&1 || die "xcrun is not available."

mkdir -p "${WORK_DIR}" "${RUNTIME_OUT}"

# ---------------------------------------------------------------------------
# Xcode / SDK
# ---------------------------------------------------------------------------
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
CLANG="$(xcrun --sdk iphoneos --find clang)"

log "iPhoneOS SDK: ${SDK_VERSION}"
log "SDK path: ${SDK_PATH}"
log "clang: ${CLANG}"

# ---------------------------------------------------------------------------
# JDK
# OpenJDK mobile requires a modern Boot JDK. Prefer 27, then 26/28.
# ---------------------------------------------------------------------------
find_jdk() {
    local v
    for v in 27 26 28; do
        if /usr/libexec/java_home -v "${v}" >/dev/null 2>&1; then
            /usr/libexec/java_home -v "${v}"
            return 0
        fi
    done
    return 1
}

if [[ -z "${JAVA_HOME:-}" ]]; then
    JAVA_HOME="$(find_jdk || true)"
fi

if [[ -z "${JAVA_HOME:-}" ]]; then
    die "No compatible JDK 26/27/28 was found. Install/use a compatible Boot JDK before building."
fi

export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"

log "JAVA_HOME=${JAVA_HOME}"
java -version

# ---------------------------------------------------------------------------
# Clone/update OpenJDK Mobile
# ---------------------------------------------------------------------------
if [[ ! -d "${OPENJDK_DIR}/.git" ]]; then
    log "Cloning OpenJDK Mobile..."
    rm -rf "${OPENJDK_DIR}"
    git clone --depth=1 "${OPENJDK_REPO}" "${OPENJDK_DIR}"
else
    log "Updating OpenJDK Mobile..."
    git -C "${OPENJDK_DIR}" fetch --depth=1 origin
    git -C "${OPENJDK_DIR}" reset --hard FETCH_HEAD
fi

# ---------------------------------------------------------------------------
# Clone/update FreeJ2ME
# ---------------------------------------------------------------------------
if [[ ! -d "${FREEJ2ME_DIR}/.git" ]]; then
    log "Cloning FreeJ2ME..."
    rm -rf "${FREEJ2ME_DIR}"
    git clone --depth=1 "${FREEJ2ME_REPO}" "${FREEJ2ME_DIR}"
else
    log "Updating FreeJ2ME..."
    git -C "${FREEJ2ME_DIR}" fetch --depth=1 origin
    git -C "${FREEJ2ME_DIR}" reset --hard FETCH_HEAD
fi

# ---------------------------------------------------------------------------
# Download mobile-support
# ---------------------------------------------------------------------------
SUPPORT_URL="${MOBILE_SUPPORT_URL:-https://github.com/openjdk/mobile/releases/download/mobile-support-20250106/mobile-support-20250106.zip}"
SUPPORT_ZIP="${WORK_DIR}/mobile-support.zip"

if [[ ! -f "${SUPPORT_ZIP}" ]]; then
    log "Downloading mobile-support..."
    curl -L --fail --retry 3 --retry-delay 2 -o "${SUPPORT_ZIP}" "${SUPPORT_URL}"
fi

rm -rf "${SUPPORT_DIR}"
mkdir -p "${SUPPORT_DIR}"
ditto -x -k "${SUPPORT_ZIP}" "${SUPPORT_DIR}"

# Some mobile-support archives contain support/support/... .
# Detect the actual support root instead of assuming a fixed nesting level.
if [[ -d "${SUPPORT_DIR}/support/libffi" ]]; then
    SUPPORT_ROOT="${SUPPORT_DIR}/support"
elif [[ -d "${SUPPORT_DIR}/support/support/libffi" ]]; then
    SUPPORT_ROOT="${SUPPORT_DIR}/support/support"
else
    SUPPORT_ROOT="$(find "${SUPPORT_DIR}" -type d -name libffi -print -quit | sed 's#/libffi$##')"
fi

[[ -n "${SUPPORT_ROOT}" ]] || die "Could not locate libffi inside mobile-support."
[[ -d "${SUPPORT_ROOT}/libffi" ]] || die "Invalid mobile-support layout: ${SUPPORT_ROOT}/libffi not found."

LIBFFI_INCLUDE="${SUPPORT_ROOT}/libffi/include"
LIBFFI_LIB="${SUPPORT_ROOT}/libffi/lib"

[[ -d "${LIBFFI_INCLUDE}" ]] || die "libffi include directory not found: ${LIBFFI_INCLUDE}"
[[ -d "${LIBFFI_LIB}" ]] || die "libffi library directory not found: ${LIBFFI_LIB}"

# CUPS is located under support/support/cups-2.3.6/cups/cups.h in the
# mobile-support archive currently used by this project.
CUPS_INCLUDE="$(find "${SUPPORT_ROOT}" -type f -path '*/cups/cups.h' -print -quit | xargs -r dirname | xargs -r dirname)"

if [[ -z "${CUPS_INCLUDE}" || ! -f "${CUPS_INCLUDE}/cups/cups.h" ]]; then
    # Fallback: locate cups-*/cups/cups.h and use the parent of cups/.
    CUPS_HEADER="$(find "${SUPPORT_DIR}" -type f -path '*/cups/cups.h' -print -quit)"
    if [[ -n "${CUPS_HEADER}" ]]; then
        CUPS_INCLUDE="$(dirname "$(dirname "${CUPS_HEADER}")")"
    fi
fi

[[ -n "${CUPS_INCLUDE}" ]] || die "Could not locate CUPS include directory."
[[ -f "${CUPS_INCLUDE}/cups/cups.h" ]] || die "CUPS header validation failed: ${CUPS_INCLUDE}/cups/cups.h"

log "Support root: ${SUPPORT_ROOT}"
log "libffi include: ${LIBFFI_INCLUDE}"
log "libffi lib: ${LIBFFI_LIB}"
log "CUPS include: ${CUPS_INCLUDE}"
log "CUPS header validated: ${CUPS_INCLUDE}/cups/cups.h"

# ---------------------------------------------------------------------------
# OpenJDK configure bootstrap
#
# Git snapshots do not always contain a root-level autogen.sh.
# Depending on the OpenJDK revision, the bootstrap script is normally in
# make/autoconf, or configure may already be generated.
# ---------------------------------------------------------------------------
cd "${OPENJDK_DIR}"

log "Preparing OpenJDK configure script..."

if [[ -x "${OPENJDK_DIR}/configure" ]]; then
    log "Using existing OpenJDK configure."

elif [[ -x "${OPENJDK_DIR}/autogen.sh" ]]; then
    log "Running OpenJDK root autogen.sh..."
    bash "${OPENJDK_DIR}/autogen.sh"

elif [[ -x "${OPENJDK_DIR}/make/autoconf/autogen.sh" ]]; then
    log "Running OpenJDK make/autoconf/autogen.sh..."
    bash "${OPENJDK_DIR}/make/autoconf/autogen.sh"

elif [[ -x "${OPENJDK_DIR}/make/autoconf/autoreconf.sh" ]]; then
    log "Running OpenJDK make/autoconf/autoreconf.sh..."
    bash "${OPENJDK_DIR}/make/autoconf/autoreconf.sh"

elif command -v autoreconf >/dev/null 2>&1 && [[ -f "${OPENJDK_DIR}/configure.ac" ]]; then
    log "Running generic autoreconf..."
    autoreconf -fiv

else
    log "Searching for an OpenJDK bootstrap script..."
    BOOTSTRAP="$(find "${OPENJDK_DIR}/make" "${OPENJDK_DIR}" \
        -maxdepth 5 \
        -type f \
        \( -name autogen.sh -o -name autoreconf.sh \) \
        -print -quit 2>/dev/null || true)"

    if [[ -n "${BOOTSTRAP}" ]]; then
        log "Using bootstrap script: ${BOOTSTRAP}"
        bash "${BOOTSTRAP}"
    else
        die "Unable to generate OpenJDK configure script. No configure, autogen.sh, autoreconf.sh, or usable configure.ac/autoreconf was found."
    fi
fi

[[ -x "${OPENJDK_DIR}/configure" ]] || die "OpenJDK configure script was not generated."

# ---------------------------------------------------------------------------
# Configure OpenJDK Mobile
# IMPORTANT:
# Do not pass --disable-manpages or --disable-jvm-feature-serviceability-agent.
# Those options are not accepted by the OpenJDK Mobile configure used here.
# ---------------------------------------------------------------------------
OPENJDK_BUILD="${WORK_DIR}/openjdk-build"
rm -rf "${OPENJDK_BUILD}"
mkdir -p "${OPENJDK_BUILD}"

cd "${OPENJDK_BUILD}"

log "Configuring OpenJDK Mobile..."

"${OPENJDK_DIR}/configure" \
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

# ---------------------------------------------------------------------------
# Build static runtime pieces
# ---------------------------------------------------------------------------
log "Building OpenJDK static-libs-image..."
make JOBS="${JOBS:-$(sysctl -n hw.ncpu)}" static-libs-image

if make JOBS="${JOBS:-$(sysctl -n hw.ncpu)}" help >/dev/null 2>&1; then
    if make JOBS="${JOBS:-$(sysctl -n hw.ncpu)}" static-jdk-image >/dev/null 2>&1; then
        log "static-jdk-image built successfully."
    else
        log "static-jdk-image target unavailable or failed; continuing with static-libs-image."
    fi
fi

# ---------------------------------------------------------------------------
# Locate generated runtime artifacts
# ---------------------------------------------------------------------------
log "Collecting generated runtime artifacts..."

rm -rf "${RUNTIME_OUT}"
mkdir -p "${RUNTIME_OUT}"

FOUND=0

while IFS= read -r -d '' f; do
    cp -R "${f}" "${RUNTIME_OUT}/"
    FOUND=1
done < <(
    find "${OPENJDK_BUILD}" \
        -type d \
        \( -name 'static-libs' -o -name 'static-libs-image' -o -name 'static-jdk-image' \) \
        -print0
)

while IFS= read -r -d '' f; do
    cp "${f}" "${RUNTIME_OUT}/"
    FOUND=1
done < <(
    find "${OPENJDK_BUILD}" \
        -type f \
        \( -name '*.a' -o -name 'libjvm.dylib' -o -name 'libjvm.a' \) \
        -print0
)

if [[ "${FOUND}" -eq 0 ]]; then
    die "OpenJDK build completed but no runtime artifacts were found."
fi

# ---------------------------------------------------------------------------
# Build FreeJ2ME when a Maven/Gradle project is actually present.
# Do not require Maven just because the repository is present.
# ---------------------------------------------------------------------------
FREEJ2ME_ARTIFACT_DIR="${RUNTIME_OUT}/freej2me"
mkdir -p "${FREEJ2ME_ARTIFACT_DIR}"

if [[ -f "${FREEJ2ME_DIR}/pom.xml" ]]; then
    if command -v mvn >/dev/null 2>&1; then
        log "Building FreeJ2ME with Maven..."
        (
            cd "${FREEJ2ME_DIR}"
            mvn -B -DskipTests package
        )

        while IFS= read -r -d '' f; do
            cp "${f}" "${FREEJ2ME_ARTIFACT_DIR}/"
        done < <(find "${FREEJ2ME_DIR}" -type f -name '*.jar' -print0)
    else
        log "FreeJ2ME has a pom.xml but Maven is unavailable; skipping FreeJ2ME build."
    fi
else
    log "No pom.xml in FreeJ2ME repository; skipping Maven build."
fi

# Also collect any existing JARs supplied by the repository.
while IFS= read -r -d '' f; do
    base="$(basename "${f}")"
    if [[ ! -f "${FREEJ2ME_ARTIFACT_DIR}/${base}" ]]; then
        cp "${f}" "${FREEJ2ME_ARTIFACT_DIR}/"
    fi
done < <(find "${FREEJ2ME_DIR}" -type f -name '*.jar' -print0 2>/dev/null)

# ---------------------------------------------------------------------------
# Runtime manifest / xcconfig
# ---------------------------------------------------------------------------
cat > "${RUNTIME_OUT}/CoreJ2Runtime.xcconfig" <<EOF
COREJ2_RUNTIME_ROOT = ${RUNTIME_OUT}
COREJ2_IOS_SDK = ${SDK_PATH}
COREJ2_IOS_SDK_VERSION = ${SDK_VERSION}
COREJ2_OPENJDK_BUILD = ${OPENJDK_BUILD}
COREJ2_FREEJ2ME_ROOT = ${FREEJ2ME_DIR}
EOF

cat > "${RUNTIME_OUT}/RUNTIME-MANIFEST.txt" <<EOF
CoreJ2 iOS Runtime
==================

Generated: $(date '+%Y-%m-%d %H:%M:%S %z')
Xcode SDK: ${SDK_VERSION}
SDK path: ${SDK_PATH}
Boot JDK: ${JAVA_HOME}

OpenJDK source: ${OPENJDK_REPO}
FreeJ2ME source: ${FREEJ2ME_REPO}

OpenJDK build: ${OPENJDK_BUILD}
Support root: ${SUPPORT_ROOT}
libffi include: ${LIBFFI_INCLUDE}
libffi lib: ${LIBFFI_LIB}
CUPS include: ${CUPS_INCLUDE}

The configure step intentionally does NOT use:
  --disable-manpages
  --disable-jvm-feature-serviceability-agent
EOF

log "Runtime preparation completed."
log "Output: ${RUNTIME_OUT}"
find "${RUNTIME_OUT}" -maxdepth 3 -print | sed -n '1,120p'
