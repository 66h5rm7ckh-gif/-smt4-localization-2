#!/usr/bin/env bash
set -Eeuo pipefail

CCI="${1:?Usage: extract_cci.sh INPUT_CCI OUTPUT_DIR}"
OUT="${2:?Usage: extract_cci.sh INPUT_CCI OUTPUT_DIR}"
TOOL_DIR="${3:-$PWD/.3dstool}"

mkdir -p "$OUT" "$TOOL_DIR"

log() {
  printf '[extract] %s\n' "$*"
}

log "Input: $CCI"
log "Output: $OUT"

# ------------------------------------------------------------
# Check input
# ------------------------------------------------------------

if [[ ! -f "$CCI" ]]; then
  echo "ERROR: CCI file not found: $CCI" >&2
  exit 2
fi

SIZE=$(stat -c '%s' "$CCI")
SHA256=$(sha256sum "$CCI" | awk '{print $1}')

{
  echo "file=$CCI"
  echo "size_bytes=$SIZE"
  echo "sha256=$SHA256"
  echo
  echo "magic_0x100:"
  xxd -g 1 -l 16 -s 0x100 "$CCI" || true
} > "$OUT/input-info.txt"

log "Size: $SIZE bytes"
log "SHA256: $SHA256"

# ------------------------------------------------------------
# Check build dependencies
# ------------------------------------------------------------

for cmd in cmake make git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 3
  fi
done

# ------------------------------------------------------------
# Build 3dstool
# ------------------------------------------------------------

SOURCE_DIR="$TOOL_DIR/src"
BUILD_DIR="$TOOL_DIR/build"

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  log "Downloading 3dstool source..."

  rm -rf "$SOURCE_DIR"

  git clone \
    --depth 1 \
    https://github.com/dnasdw/3dstool.git \
    "$SOURCE_DIR"
else
  log "3dstool source already exists."
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log "Configuring 3dstool with CMake..."

set +e

cmake \
  -S "$SOURCE_DIR" \
  -B "$BUILD_DIR" \
  -DUSE_DEP=OFF \
  -DBUILD64=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  > "$OUT/cmake-configure.log" 2>&1

CMAKE_STATUS=$?

set -e

if [[ $CMAKE_STATUS -ne 0 ]]; then
  echo "ERROR: CMake configuration failed." >&2
  echo "See cmake-configure.log." >&2

  {
    echo
    echo "cmake_configure_status=$CMAKE_STATUS"
  } >> "$OUT/input-info.txt"

  exit 4
fi

log "CMake configuration completed."

log "Building 3dstool..."

set +e

cmake \
  --build "$BUILD_DIR" \
  --config Release \
  --parallel 2 \
  > "$OUT/cmake-build.log" 2>&1

BUILD_STATUS=$?

set -e

if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "ERROR: 3dstool compilation failed." >&2
  echo "See cmake-build.log." >&2

  {
    echo
    echo "cmake_build_status=$BUILD_STATUS"
  } >> "$OUT/input-info.txt"

  exit 5
fi

log "Compilation finished."

# ------------------------------------------------------------
# Find produced 3dstool binary
# ------------------------------------------------------------

log "Searching for 3dstool binary..."

THREEDSTOOL=""

while IFS= read -r candidate; do
  if [[ -x "$candidate" ]]; then
    THREEDSTOOL="$candidate"
    break
  fi
done < <(
  find "$BUILD_DIR" \
    -type f \
    \( -name "3dstool" -o -name "3dstool.exe" \) \
    -print
)

if [[ -z "$THREEDSTOOL" ]]; then
  echo "ERROR: 3dstool binary was not produced." >&2
  echo >&2
  echo "Files found inside build directory:" >&2

  find "$BUILD_DIR" -maxdepth 5 -type f -print \
    | sort >&2 || true

  {
    echo
    echo "binary_found=no"
    echo "cmake_build_status=$BUILD_STATUS"
  } >> "$OUT/input-info.txt"

  exit 6
fi

log "3dstool found:"
log "$THREEDSTOOL"

{
  echo
  echo "binary_found=yes"
  echo "binary_path=$THREEDSTOOL"
} >> "$OUT/input-info.txt"

# ------------------------------------------------------------
# Test 3dstool
# ------------------------------------------------------------

log "Testing 3dstool..."

set +e

"$THREEDSTOOL" \
  --help \
  > "$OUT/3dstool-help.txt" 2>&1

HELP_STATUS=$?

set -e

echo "3dstool_help_status=$HELP_STATUS" >> "$OUT/input-info.txt"

if [[ $HELP_STATUS -ne 0 ]]; then
  echo "WARNING: 3dstool --help returned status $HELP_STATUS"
fi

# ------------------------------------------------------------
# Extract CCI partition 0
# ------------------------------------------------------------

log "Extracting CCI partition 0..."

set +e

"$THREEDSTOOL" \
  -xvt0f cci \
  "$OUT/game.cxi" \
  "$CCI" \
  --header "$OUT/ncsdheader.bin" \
  > "$OUT/cci-extract.log" 2>&1

CCI_STATUS=$?

set -e

echo "cci_extract_status=$CCI_STATUS" >> "$OUT/input-info.txt"

if [[ $CCI_STATUS -ne 0 || ! -s "$OUT/game.cxi" ]]; then

  echo "CCI partition extraction failed." >&2
  echo "See cci-extract.log." >&2

  if [[ -s "$OUT/cci-extract.log" ]]; then
    echo
    echo "----- 3dstool CCI output -----"
    cat "$OUT/cci-extract.log"
    echo "------------------------------"
  fi

  exit 7
fi

{
  echo "partition0_present=yes"
  echo "partition0_size=$(stat -c '%s' "$OUT/game.cxi")"
  echo "ncsd_header_size=$(stat -c '%s' "$OUT/ncsdheader.bin")"
} >> "$OUT/input-info.txt"

log "CCI partition 0 extracted."

# ------------------------------------------------------------
# Extract CXI
# ------------------------------------------------------------

log "Extracting CXI components..."

set +e

"$THREEDSTOOL" \
  -xvtf cxi \
  "$OUT/game.cxi" \
  --header "$OUT/ncchheader.bin" \
  --exh "$OUT/exheader.bin" \
  --plain "$OUT/plain.bin" \
  --logo "$OUT/logo.bin" \
  --exefs "$OUT/exefs.bin" \
  --romfs "$OUT/romfs.bin" \
  > "$OUT/cxi-extract.log" 2>&1

CXI_STATUS=$?

set -e

echo "cxi_extract_status=$CXI_STATUS" >> "$OUT/input-info.txt"

if [[ $CXI_STATUS -ne 0 || ! -s "$OUT/romfs.bin" ]]; then

  echo "CXI extraction did not produce romfs.bin." >&2
  echo "See cxi-extract.log." >&2

  if [[ -s "$OUT/cxi-extract.log" ]]; then
    echo
    echo "----- 3dstool CXI output -----"
    cat "$OUT/cxi-extract.log"
    echo "------------------------------"
  fi

  exit 8
fi

log "CXI extracted successfully."

# ------------------------------------------------------------
# Extract RomFS directory
# ------------------------------------------------------------

log "Extracting RomFS directory..."

set +e

"$THREEDSTOOL" \
  -xvtf romfs \
  "$OUT/romfs.bin" \
  --romfs-dir "$OUT/romfs" \
  > "$OUT/romfs-extract.log" 2>&1

ROMFS_STATUS=$?

set -e

echo "romfs_extract_status=$ROMFS_STATUS" >> "$OUT/input-info.txt"

if [[ $ROMFS_STATUS -ne 0 ]]; then

  echo "RomFS extraction failed." >&2
  echo "See romfs-extract.log." >&2

  if [[ -s "$OUT/romfs-extract.log" ]]; then
    echo
    echo "----- 3dstool RomFS output -----"
    cat "$OUT/romfs-extract.log"
    echo "--------------------------------"
  fi

  exit 9
fi

log "RomFS extracted successfully."

# ------------------------------------------------------------
# Generate manifest
# ------------------------------------------------------------

log "Generating RomFS manifest..."

find "$OUT/romfs" \
  -type f \
  -printf '%s\t%p\n' \
  | sort -n \
  > "$OUT/romfs-files.tsv"

ROMFS_COUNT=$(find "$OUT/romfs" -type f | wc -l)
ROMFS_SIZE=$(du -sb "$OUT/romfs" | awk '{print $1}')

{
  echo "romfs_file_count=$ROMFS_COUNT"
  echo "romfs_total_bytes=$ROMFS_SIZE"
} >> "$OUT/input-info.txt"

log "RomFS files: $ROMFS_COUNT"
log "RomFS size: $ROMFS_SIZE bytes"

log "Extraction complete."

exit 0
