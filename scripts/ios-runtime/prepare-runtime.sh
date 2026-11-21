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

mkdir -p "${BUILD_ROOT}"
rm -rf "${OUT_ROOT}"
mkdir -p "${OUT_ROOT}/lib" "${OUT_ROOT}/include" "${OUT_ROOT}/jdk"

log() {
    echo "[CoreJ2 runtime] $*"
}

fail() {
    echo "[CoreJ2 runtime] ERROR: $*" >&2
    exit 1
}

# Host tools
command -v git >/dev/null 2>&1 || fail "git is required."
command -v curl >/dev/null 2>&1 || fail "curl is required."
command -v unzip >/dev/null 2>&1 || fail "unzip is required."
command -v rsync >/dev/null 2>&1 || fail "rsync is required."
command -v xcrun >/dev/null 2>&1 || fail "Xcode command-line tools are required."

command -v autoconf >/dev/null 2>&1 || brew install autoconf
command -v ant >/dev/null 2>&1 || brew install ant

# Current openjdk/mobile requires Boot JDK 26/27/28.
JAVA_HOME="${JAVA_HOME:-}"
if [[ -z "${JAVA_HOME}" ]]; then
    JAVA_HOME="$(/usr/libexec/java_home -v 26 2>/dev/null || true)"
fi

[[ -n "${JAVA_HOME}" && -x "${JAVA_HOME}/bin/java" && -x "${JAVA_HOME}/bin/javac" ]] ||     fail "JDK 26 is required. JAVA_HOME=${JAVA_HOME:-<empty>}"

export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"

JAVA_VERSION="$("${JAVA_HOME}/bin/java" -version 2>&1 | head -n 1)"
JAVA_MAJOR="$("${JAVA_HOME}/bin/java" -version 2>&1 | sed -nE 's/.*version "([0-9]+).*/\1/p')"

log "Boot JDK: ${JAVA_HOME}"
log "Java version: ${JAVA_VERSION}"

case "${JAVA_MAJOR}" in
    26|27|28) ;;
    *) fail "OpenJDK Mobile requires JDK 26, 27 or 28; found ${JAVA_MAJOR}." ;;
esac

# OpenJDK Mobile
if [[ ! -d "${OJDK_ROOT}/.git" ]]; then
    log "Cloning OpenJDK Mobile"
    git clone --depth 1 https://github.com/openjdk/mobile.git "${OJDK_ROOT}"
fi

# Mobile support
if [[ ! -f "${SUPPORT_ZIP}" ]]; then
    log "Downloading mobile-support"
    curl -fL --retry 4 --retry-delay 2         -o "${SUPPORT_ZIP}"         https://download2.gluonhq.com/mobile/mobile-support-20250106.zip
fi

rm -rf "${SUPPORT_ROOT}"
mkdir -p "${SUPPORT_ROOT}"
unzip -q "${SUPPORT_ZIP}" -d "${SUPPORT_ROOT}"

# Find libffi instead of assuming one exact archive layout.
LIBFFI_INCLUDE=""
LIBFFI_LIB=""

[[ -d "${SUPPORT_ROOT}/libffi/include" ]] &&     LIBFFI_INCLUDE="${SUPPORT_ROOT}/libffi/include"

if [[ -d "${SUPPORT_ROOT}/libffi/libs" ]]; then
    LIBFFI_LIB="${SUPPORT_ROOT}/libffi/libs"
elif [[ -d "${SUPPORT_ROOT}/libffi/lib" ]]; then
    LIBFFI_LIB="${SUPPORT_ROOT}/libffi/lib"
fi

if [[ -z "${LIBFFI_INCLUDE}" ]]; then
    LIBFFI_INCLUDE="$(find "${SUPPORT_ROOT}" -type f -path '*/libffi*/include/ffi.h' -print -quit 2>/dev/null | xargs -r dirname || true)"
fi

if [[ -z "${LIBFFI_LIB}" ]]; then
    LIBFFI_LIB="$(find "${SUPPORT_ROOT}" -type f \( -name 'libffi.a' -o -name 'libffi.dylib' \) -print -quit 2>/dev/null | xargs -r dirname || true)"
fi

[[ -n "${LIBFFI_INCLUDE}" && -d "${LIBFFI_INCLUDE}" ]] ||     fail "libffi headers not found under ${SUPPORT_ROOT}"

[[ -n "${LIBFFI_LIB}" && -d "${LIBFFI_LIB}" ]] ||     fail "libffi libraries not found under ${SUPPORT_ROOT}"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
BUILD_CONF="ios-aarch64-zero-release"

cd "${OJDK_ROOT}"

if [[ ! -f "build/${BUILD_CONF}/spec.gmk" ]]; then
    log "Configuring OpenJDK Mobile for iPhoneOS"
    bash ./configure         --disable-warnings-as-errors         --openjdk-target=aarch64-macos-ios         --with-boot-jdk="${JAVA_HOME}"         --with-libffi-include="${LIBFFI_INCLUDE}"         --with-libffi-lib="${LIBFFI_LIB}"         --with-cups=none         --with-sysroot="${SDK_PATH}"
else
    log "OpenJDK configuration already exists"
fi

log "Building OpenJDK Mobile static libraries"
make CONF="${BUILD_CONF}" static-libs-image

log "Building OpenJDK Mobile static JDK image"
make CONF="${BUILD_CONF}" static-jdk-image

STATIC_ROOT="${OJDK_ROOT}/build/${BUILD_CONF}/images/static-libs"
JDK_ROOT="${OJDK_ROOT}/build/${BUILD_CONF}/images/jdk"
LIBJVM="${STATIC_ROOT}/lib/zero/libjvm.a"

[[ -f "${LIBJVM}" ]] || fail "libjvm.a was not produced."
[[ -d "${JDK_ROOT}" ]] || fail "JDK image was not produced."

log "Copying JDK image"
rsync -a --delete "${JDK_ROOT}/" "${OUT_ROOT}/jdk/"

log "Copying OpenJDK static libraries"
rsync -a "${STATIC_ROOT}/lib/" "${OUT_ROOT}/lib/"

JNI_INCLUDE="$(find "${OJDK_ROOT}/build/${BUILD_CONF}"     -type d -path '*/support/headers/java.base' -print -quit 2>/dev/null || true)"

[[ -n "${JNI_INCLUDE}" ]] ||     JNI_INCLUDE="${OJDK_ROOT}/src/java.base/share/native/include"

[[ -d "${JNI_INCLUDE}" ]] || fail "JNI include directory not found."
cp -R "${JNI_INCLUDE}/." "${OUT_ROOT}/include/"

# FreeJ2ME
if [[ ! -d "${FREEJ2ME_ROOT}/.git" ]]; then
    log "Cloning FreeJ2ME"
    git clone --depth 1 https://github.com/hex007/freej2me.git "${FREEJ2ME_ROOT}"
fi

rm -rf "${FREEJ2ME_CLASSES}"
mkdir -p "${FREEJ2ME_CLASSES}"

FREE_SOURCES_LIST="${BUILD_ROOT}/freej2me-sources.txt"
find "${FREEJ2ME_ROOT}/src" -type f -name '*.java' | sort > "${FREE_SOURCES_LIST}"
find "${BOOTSTRAP_ROOT}" -maxdepth 1 -type f -name '*.java' | sort >> "${FREE_SOURCES_LIST}"

[[ -s "${FREE_SOURCES_LIST}" ]] || fail "No FreeJ2ME/CoreJ2 Java sources found."

log "Compiling FreeJ2ME + CoreJ2 bootstrap classes"
"${JAVA_HOME}/bin/javac"     -encoding UTF-8     -g:none     -source 8     -target 8     -d "${FREEJ2ME_CLASSES}"     @"${FREE_SOURCES_LIST}"

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

[[ -f "${FREEJ2ME_JAR}" ]] || fail "freej2me-core.jar was not created."

# Xcode linker configuration
mapfile -t STATIC_LIBS < <(find "${OUT_ROOT}/lib" -type f -name '*.a' | sort)
[[ "${#STATIC_LIBS[@]}" -gt 0 ]] || fail "No OpenJDK static archives found."

STATIC_LDFLAGS=""
for lib in "${STATIC_LIBS[@]}"; do
    STATIC_LDFLAGS+=" \"${lib}\""
done

cat > "${OUT_ROOT}/CoreJ2Runtime.xcconfig" <<CFG
// Generated by prepare-runtime.sh
COREJ2_RUNTIME_ROOT = ${OUT_ROOT}
HEADER_SEARCH_PATHS = \$(inherited) "${OUT_ROOT}/include"
LIBRARY_SEARCH_PATHS = \$(inherited) "${OUT_ROOT}/lib"
OTHER_LDFLAGS = \$(inherited)${STATIC_LDFLAGS} -lc++ -lz -liconv
CFG

OPENJDK_COMMIT="$(git -C "${OJDK_ROOT}" rev-parse HEAD)"
FREEJ2ME_COMMIT="$(git -C "${FREEJ2ME_ROOT}" rev-parse HEAD)"
LIBJVM_BYTES="$(wc -c < "${LIBJVM}" | tr -d ' ')"
FREEJ2ME_BYTES="$(wc -c < "${FREEJ2ME_JAR}" | tr -d ' ')"

cat > "${OUT_ROOT}/RUNTIME-MANIFEST.txt" <<MANIFEST
CoreJ2 embedded iOS runtime

iPhoneOS SDK: ${SDK_VERSION}
Boot JDK: ${JAVA_VERSION}

OpenJDK Mobile commit:
${OPENJDK_COMMIT}

FreeJ2ME commit:
${FREEJ2ME_COMMIT}

libjvm.a bytes:
${LIBJVM_BYTES}

freej2me-core.jar bytes:
${FREEJ2ME_BYTES}

Static archives:
${#STATIC_LIBS[@]}

CUPS:
disabled

JDK image:
${OUT_ROOT}/jdk

FreeJ2ME/CoreJ2 jar:
${OUT_ROOT}/freej2me-core.jar
MANIFEST

log "Runtime preparation completed"
cat "${OUT_ROOT}/RUNTIME-MANIFEST.txt"
