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
mkdir -p "${BUILD_ROOT}" "${OUT_ROOT}"
rm -rf "${OUT_ROOT}" && mkdir -p "${OUT_ROOT}/lib" "${OUT_ROOT}/include" "${OUT_ROOT}/jdk"
log(){ echo "[CoreJ2 runtime] $*"; }
command -v autoconf >/dev/null 2>&1 || brew install autoconf
command -v ant >/dev/null 2>&1 || brew install ant
export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 26 2>/dev/null || true)}"
[[ -n "${JAVA_HOME}" && -x "${JAVA_HOME}/bin/javac" ]] || { echo "ERROR: JDK 26 is required." >&2; exit 1; }
if [[ ! -d "${OJDK_ROOT}/.git" ]]; then git clone --depth 1 https://github.com/openjdk/mobile.git "${OJDK_ROOT}"; fi
if [[ ! -f "${SUPPORT_ZIP}" ]]; then curl -fL --retry 4 -o "${SUPPORT_ZIP}" https://download2.gluonhq.com/mobile/mobile-support-20250106.zip; fi
rm -rf "${SUPPORT_ROOT}" && mkdir -p "${SUPPORT_ROOT}" && unzip -q "${SUPPORT_ZIP}" -d "${SUPPORT_ROOT}"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
BUILD_CONF="ios-aarch64-zero-release"
cd "${OJDK_ROOT}"
if [[ ! -f "build/${BUILD_CONF}/spec.gmk" ]]; then
  log "Configuring OpenJDK Mobile for iPhoneOS"
  bash ./configure --disable-warnings-as-errors --openjdk-target=aarch64-macos-ios --with-boot-jdk="${JAVA_HOME}" --with-libffi-include="${SUPPORT_ROOT}/libffi/include" --with-libffi-lib="${SUPPORT_ROOT}/libffi/libs" --with-cups-include="${SUPPORT_ROOT}/cups-2.3.6" --with-sysroot="${SDK_PATH}"
fi
log "Building OpenJDK Mobile static libraries"
make CONF="${BUILD_CONF}" static-libs-image
log "Building OpenJDK Mobile static JDK image"
make CONF="${BUILD_CONF}" static-jdk-image
STATIC_ROOT="${OJDK_ROOT}/build/${BUILD_CONF}/images/static-libs"
JDK_ROOT="${OJDK_ROOT}/build/${BUILD_CONF}/images/jdk"
LIBJVM="${STATIC_ROOT}/lib/zero/libjvm.a"
[[ -f "${LIBJVM}" && -d "${JDK_ROOT}" ]] || { echo "ERROR: OpenJDK Mobile artifacts missing" >&2; exit 1; }
rsync -a --delete "${JDK_ROOT}/" "${OUT_ROOT}/jdk/"
rsync -a "${STATIC_ROOT}/lib/" "${OUT_ROOT}/lib/"
JNI_INCLUDE="$(find "${OJDK_ROOT}/build/${BUILD_CONF}" -type d -path '*/support/headers/java.base' -print -quit)"
[[ -n "${JNI_INCLUDE}" ]] || JNI_INCLUDE="${OJDK_ROOT}/src/java.base/share/native/include"
cp -R "${JNI_INCLUDE}/." "${OUT_ROOT}/include/"
if [[ ! -d "${FREEJ2ME_ROOT}/.git" ]]; then git clone --depth 1 https://github.com/hex007/freej2me.git "${FREEJ2ME_ROOT}"; fi
rm -rf "${FREEJ2ME_CLASSES}" && mkdir -p "${FREEJ2ME_CLASSES}"
FREE_SOURCES_LIST="${BUILD_ROOT}/freej2me-sources.txt"
find "${FREEJ2ME_ROOT}/src" -type f -name '*.java' | sort > "${FREE_SOURCES_LIST}"
find "${BOOTSTRAP_ROOT}" -maxdepth 1 -type f -name '*.java' | sort >> "${FREE_SOURCES_LIST}"
log "Compiling FreeJ2ME + CoreJ2 bootstrap Java classes"
"${JAVA_HOME}/bin/javac" -encoding UTF-8 -g:none -source 8 -target 8 -d "${FREEJ2ME_CLASSES}" @"${FREE_SOURCES_LIST}"
FREEJ2ME_JAR="${OUT_ROOT}/freej2me-core.jar"
rm -f "${FREEJ2ME_JAR}" && cd "${FREEJ2ME_CLASSES}" && "${JAVA_HOME}/bin/jar" cf "${FREEJ2ME_JAR}" .
cd "${FREEJ2ME_ROOT}"
[[ -d resources ]] && "${JAVA_HOME}/bin/jar" uf "${FREEJ2ME_JAR}" resources || true
[[ -d META-INF ]] && "${JAVA_HOME}/bin/jar" uf "${FREEJ2ME_JAR}" META-INF || true
mapfile -t STATIC_LIBS < <(find "${OUT_ROOT}/lib" -type f -name '*.a' | sort)
[[ "${#STATIC_LIBS[@]}" -gt 0 ]] || { echo "ERROR: no OpenJDK static libraries found" >&2; exit 1; }
cat > "${OUT_ROOT}/CoreJ2Runtime.xcconfig" <<CFG
COREJ2_RUNTIME_ROOT = ${OUT_ROOT}
HEADER_SEARCH_PATHS = \$(inherited) "${OUT_ROOT}/include"
LIBRARY_SEARCH_PATHS = \$(inherited) "${OUT_ROOT}/lib"
OTHER_LDFLAGS = \$(inherited) ${STATIC_LIBS[*]} -lc++ -lz -liconv
CFG
{
 echo "CoreJ2 embedded runtime"
 echo "OpenJDK commit: $(git -C "${OJDK_ROOT}" rev-parse HEAD)"
 echo "FreeJ2ME commit: $(git -C "${FREEJ2ME_ROOT}" rev-parse HEAD)"
 echo "libjvm bytes: $(wc -c < "${LIBJVM}" | tr -d ' ')"
 echo "FreeJ2ME jar bytes: $(wc -c < "${FREEJ2ME_JAR}" | tr -d ' ')"
 echo "Static archives: ${#STATIC_LIBS[@]}"
} > "${OUT_ROOT}/RUNTIME-MANIFEST.txt"
log "Runtime prepared at ${OUT_ROOT}"
cat "${OUT_ROOT}/RUNTIME-MANIFEST.txt"
