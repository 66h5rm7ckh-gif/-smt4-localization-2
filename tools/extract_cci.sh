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
# Download official prebuilt 3dstool
# ------------------------------------------------------------

THREEDSTOOL="$TOOL_DIR/3dstool"

if [[ ! -x "$THREEDSTOOL" ]]; then

  log "Downloading official 3dstool v1.2.6..."

  ARCHIVE="$TOOL_DIR/3dstool_linux_x86_64.tar.gz"

  curl \
    -L \
    --fail \
    --retry 3 \
    -o "$ARCHIVE" \
    "https://github.com/dnasdw/3dstool/releases/download/v1.2.6/3dstool_linux_x86_64.tar.gz"

  log "Extracting 3dstool..."

  tar \
    -xzf "$ARCHIVE" \
    -C "$TOOL_DIR"

  # The archive normally contains a file named "3dstool".
  # If it was extracted into a subdirectory, find it.

  if [[ -f "$TOOL_DIR/3dstool" ]]; then
    chmod +x "$TOOL_DIR/3dstool"

  else

    FOUND=""

    while IFS= read -r candidate; do
      if [[ -f "$candidate" ]]; then
        FOUND="$candidate"
        break
      fi
    done < <(
      find "$TOOL_DIR" \
        -type f \
        -name "3dstool" \
        -print
    )

    if [[ -z "$FOUND" ]]; then
      echo "ERROR: 3dstool binary was not found after extracting archive." >&2
      echo >&2
      echo "Contents of TOOL_DIR:" >&2
      find "$TOOL_DIR" -maxdepth 3 -type f -print >&2 || true
      exit 6
    fi

    mv "$FOUND" "$THREEDSTOOL"
    chmod +x "$THREEDSTOOL"
  fi

fi

# ------------------------------------------------------------
# Verify 3dstool
# ------------------------------------------------------------

if [[ ! -x "$THREEDSTOOL" ]]; then
  echo "ERROR: 3dstool binary is missing or not executable." >&2
  exit 6
fi

log "3dstool found:"
log "$THREEDSTOOL"

set +e

"$THREEDSTOOL" \
  --help \
  > "$OUT/3dstool-help.txt" 2>&1

HELP_STATUS=$?

set -e

echo "3dstool_help_status=$HELP_STATUS" >> "$OUT/input-info.txt"

if [[ $HELP_STATUS -ne 0 ]]; then
  echo "WARNING: 3dstool --help returned $HELP_STATUS"
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

  echo "ERROR: CCI partition extraction failed." >&2
  echo "See cci-extract.log." >&2

  cat "$OUT/cci-extract.log" || true

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

  echo "ERROR: CXI extraction did not produce romfs.bin." >&2
  echo "See cxi-extract.log." >&2

  cat "$OUT/cxi-extract.log" || true

  exit 8
fi

log "CXI extracted successfully."

# ------------------------------------------------------------
# Extract RomFS
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

  echo "ERROR: RomFS extraction failed." >&2
  echo "See romfs-extract.log." >&2

  cat "$OUT/romfs-extract.log" || true

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
