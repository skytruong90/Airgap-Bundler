#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Airgap Bundle Verifier
# Verifies SHA-256 manifest of an extracted bundle directory,
# or verifies a .tar.gz bundle directly (it will extract to a temp dir).
#
# Usage:
#   ./airgap-verify.sh /path/to/extracted/bundle_dir
#   ./airgap-verify.sh --tar /path/to/bundle.tar.gz [--allow-extras]
#
# Exit codes: 0 on success, non-zero on mismatch/error.

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    die "No sha256 tool found (need sha256sum or shasum)."
  fi
}

FILES_ROOT=""
ALLOW_EXTRAS=0
BUNDLE_TGZ=""

if [[ $# -lt 1 ]]; then
  cat <<EOF
Usage:
  $0 /path/to/extracted/bundle_dir
  $0 --tar /path/to/bundle.tar.gz [--allow-extras]
EOF
  exit 1
fi

# Arg parse
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tar) BUNDLE_TGZ="${2:-}"; shift 2;;
    --allow-extras) ALLOW_EXTRAS=1; shift;;
    *) FILES_ROOT="${1:-}"; shift;;
  esac
done

TEMP_DIR=""
cleanup() { [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

if [[ -n "$BUNDLE_TGZ" ]]; then
  [[ -f "$BUNDLE_TGZ" ]] || die "Bundle not found: $BUNDLE_TGZ"
  TEMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t airgap_verify)"
  note "Extracting to temp: $TEMP_DIR"
  tar -C "$TEMP_DIR" -xzf "$BUNDLE_TGZ"
  FILES_ROOT="$TEMP_DIR"
fi

# Locate payload and manifest
if [[ -f "$FILES_ROOT/manifest.txt" && -d "$FILES_ROOT/payload" ]]; then
  ROOT="$FILES_ROOT"
elif [[ -f "$FILES_ROOT/manifest.txt" && ! -d "$FILES_ROOT/payload" ]]; then
  # maybe user pointed to the inner staging root
  ROOT="$FILES_ROOT"
elif [[ -f "$FILES_ROOT/payload/manifest.txt" ]]; then
  ROOT="$FILES_ROOT/payload"
else
  # try nested dirs
  if [[ -f "$FILES_ROOT/manifest.txt" ]]; then
    ROOT="$FILES_ROOT"
  else
    die "Could not find manifest.txt in: $FILES_ROOT"
  fi
fi

MANIFEST="$ROOT/manifest.txt"
PAYLOAD_DIR="$ROOT/payload"
[[ -f "$MANIFEST" ]] || die "manifest.txt not found at: $MANIFEST"

# Verify each line of manifest
note "Verifying manifest: $MANIFEST"
MISMATCH=0
COUNT=0

while IFS= read -r line; do
  [[ "$line" =~ ^# ]] && continue
  [[ -z "$line" ]] && continue

  # Expect: HASH  SIZE  RELPATH
  hash=$(echo "$line" | awk '{print $1}')
  size=$(echo "$line" | awk '{print $2}')
  rel=$(echo "$line" | cut -d' ' -f3-)

  # Files can be under payload/ in the extracted bundle
  if [[ -d "$PAYLOAD_DIR" ]]; then
    f="$PAYLOAD_DIR/$rel"
  else
    f="$ROOT/$rel"
  fi

  if [[ ! -f "$f" ]]; then
    warn "Missing file: $rel"
    MISMATCH=1
    continue
  fi

  sz_actual=$(if [[ "$(uname)" == "Darwin" ]]; then stat -f %z "$f"; else stat -c %s "$f"; fi)
  hash_actual=$(sha256_file "$f")

  if [[ "$sz_actual" != "$size" ]]; then
    warn "Size mismatch: $rel (expected $size, got $sz_actual)"
    MISMATCH=1
  fi
  if [[ "$hash_actual" != "$hash" ]]; then
    warn "Hash mismatch: $rel"
    MISMATCH=1
  fi

  COUNT=$((COUNT+1))
done < "$MANIFEST"

note "Checked $COUNT files from manifest."

# Check for extras if not allowed
if [[ $ALLOW_EXTRAS -eq 0 ]]; then
  note "Checking for unexpected extra files..."
  # Build a set of manifest paths
  mapfile -t manifest_paths < <(grep -v '^#' "$MANIFEST" | awk '{print substr($0, index($0,$3))}')
  declare -A manifest_map
  for p in "${manifest_paths[@]}"; do manifest_map["$p"]=1; done

  BASE_SEARCH="$PAYLOAD_DIR"
  [[ -d "$BASE_SEARCH" ]] || BASE_SEARCH="$ROOT"

  while IFS= read -r -d '' f; do
    rel="${f#$BASE_SEARCH/}"
    # Ignore manifest.txt and bundle_notes.txt themselves
    [[ "$rel" == "manifest.txt" || "$rel" == "bundle_notes.txt" ]] && continue
    if [[ -z "${manifest_map["$rel"]+x}" ]]; then
      warn "Extra file not in manifest: $rel"
      MISMATCH=1
    fi
  done < <(find "$BASE_SEARCH" -type f -print0)
else
  note "Extras allowed by flag."
fi

if [[ $MISMATCH -eq 0 ]]; then
  echo "[OK] Manifest verified successfully."
  exit 0
else
  echo "[FAIL] Verification failed. See warnings above."
  exit 2
fi

