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

if ! command -v cmake >/dev/null 2>&1; then
  echo "ERROR: cmake is required" >&2
  exit 3
fi

if [[ ! -x "$TOOL_DIR/build/3dstool" ]]; then
  log "Building 3dstool..."

  rm -rf "$TOOL_DIR/src"

  git clone --depth 1 \
    https://github.com/dnasdw/3dstool.git \
    "$TOOL_DIR/src"

  cmake \
    -S "$TOOL_DIR/src" \
    -B "$TOOL_DIR/build" \
    -DUSE_DEP=OFF \
    -DBUILD64=ON

  cmake \
    --build "$TOOL_DIR/build" \
    --parallel 2
fi

THREEDSTOOL="$TOOL_DIR/build/3dstool"

if [[ ! -x "$THREEDSTOOL" ]]; then
  echo "ERROR: 3dstool binary was not produced" >&2
  exit 4
fi

"$THREEDSTOOL" --help \
  > "$OUT/3dstool-help.txt" 2>&1 || true

log "Extracting CCI partition 0..."

set +e

"$THREEDSTOOL" \
  -xvt0f cci \
  "$OUT/game.cxi" \
  "$CCI" \
  --header "$OUT/ncsdheader.bin" \
  > "$OUT/cci-extract.log" 2>&1

STATUS=$?

set -e

if [[ $STATUS -ne 0 || ! -s "$OUT/game.cxi" ]]; then

  {
    echo "cci_extract_status=$STATUS"

    if [[ -s "$OUT/game.cxi" ]]; then
      echo "partition0_present=yes"
    else
      echo "partition0_present=no"
    fi

  } >> "$OUT/input-info.txt"

  echo "CCI partition extraction failed."
  echo "See cci-extract.log."

  exit $STATUS
fi

{
  echo "cci_extract_status=0"
  echo "partition0_size=$(stat -c '%s' "$OUT/game.cxi")"
  echo "ncsd_header_size=$(stat -c '%s' "$OUT/ncsdheader.bin")"
} >> "$OUT/input-info.txt"

log "CCI partition 0 extracted."

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

STATUS=$?

set -e

echo "cxi_extract_status=$STATUS" >> "$OUT/input-info.txt"

if [[ $STATUS -ne 0 || ! -s "$OUT/romfs.bin" ]]; then
  echo "CXI extraction did not produce romfs.bin."
  echo "See cxi-extract.log."
  exit $STATUS
fi

log "CXI extracted."

log "Extracting RomFS directory..."

set +e

"$THREEDSTOOL" \
  -xvtf romfs \
  "$OUT/romfs.bin" \
  --romfs-dir "$OUT/romfs" \
  > "$OUT/romfs-extract.log" 2>&1

STATUS=$?

set -e

echo "romfs_extract_status=$STATUS" >> "$OUT/input-info.txt"

if [[ $STATUS -ne 0 ]]; then
  echo "RomFS extraction failed."
  echo "See romfs-extract.log."
  exit $STATUS
fi

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
