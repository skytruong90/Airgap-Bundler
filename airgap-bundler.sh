#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Airgap Bundler: Hardened packaging for air-gapped transfers.
# Creates a tar.gz containing only whitelisted file types, strips EXIF (optional),
# normalizes permissions, generates a SHA-256 manifest, optional ClamAV scan,
# and optional GPG detached signature.
#
# Usage:
#   ./airgap-bundler.sh --src <dir> [--out ./dist] [--org "Org"] [--label "UNCLASSIFIED"] \
#       [--include-ext "pdf,txt,csv,..."] [--max-size-mb 100] [--strip-exif] [--clamav] \
#       [--allow-binaries] [--sign --gpg-key "<key-id>"]
#
# Exit codes: 0 on success, non-zero on error.

# ---------- Defaults ----------
SRC=""
OUT="./dist"
ORG="Org"
LABEL="UNCLASSIFIED"
INCLUDE_EXT="pdf,txt,csv,json,xml,yaml,yml,md,png,jpg,jpeg,gif"
MAX_SIZE_MB=100
STRIP_EXIF=0
RUN_CLAMAV=0
ALLOW_BINARIES=0
DO_SIGN=0
GPG_KEY=""

# ---------- Helpers ----------
die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

# sha256 tool detection (sha256sum on Linux; shasum -a 256 on macOS)
sha256_file() {
  local f="$1"
  if have sha256sum; then
    sha256sum "$f" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    die "No sha256 tool found (need sha256sum or shasum)."
  fi
}

filesize_bytes() {
  local f="$1"
  if [[ "$(uname)" == "Darwin" ]]; then
    stat -f %z "$f"
  else
    stat -c %s "$f"
  fi
}

timestamp() { date +"%Y-%m-%d_%H%M%S"; }

usage() {
  cat <<EOF
Airgap Bundler

Required:
  --src <dir>                Source directory to collect from

Options:
  --out <dir>                Output directory (default: ./dist)
  --org "<name>"             Org/lab/project name for bundle tag
  --label "<text>"           Marking/classification label (default: UNCLASSIFIED)
  --include-ext "a,b,c"      Whitelist extensions (no dots). Default:
                             ${INCLUDE_EXT}
  --allow-binaries           Permit .bin,.hex in addition to includes
  --max-size-mb <N>          Skip files larger than N MB (default: 100)
  --strip-exif               Strip EXIF metadata from images (if exiftool exists)
  --clamav                   Run ClamAV scan (if clamscan exists)
  --sign                     GPG-detached sign the bundle
  --gpg-key "<keyID|email>"  GPG key to use for signing

Examples:
  ./airgap-bundler.sh --src ./export --out ./dist --org "RaptorTeam" \\
    --label "CUI" --include-ext "pdf,txt,md,png,jpg" --strip-exif --clamav

EOF
}

# ---------- Parse Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="${2:-}"; shift 2;;
    --out) OUT="${2:-}"; shift 2;;
    --org) ORG="${2:-}"; shift 2;;
    --label) LABEL="${2:-}"; shift 2;;
    --include-ext) INCLUDE_EXT="${2:-}"; shift 2;;
    --max-size-mb) MAX_SIZE_MB="${2:-}"; shift 2;;
    --strip-exif) STRIP_EXIF=1; shift;;
    --clamav) RUN_CLAMAV=1; shift;;
    --allow-binaries) ALLOW_BINARIES=1; shift;;
    --sign) DO_SIGN=1; shift;;
    --gpg-key) GPG_KEY="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1 (see --help)";;
  esac
done

[[ -n "$SRC" ]] || { usage; die "--src is required"; }
[[ -d "$SRC" ]] || die "Source directory not found: $SRC"
mkdir -p "$OUT"

# ---------- Build extension filter ----------
IFS=',' read -r -a EXT_ARR <<< "$INCLUDE_EXT"
if [[ $ALLOW_BINARIES -eq 1 ]]; then
  EXT_ARR+=("bin" "hex")
fi

# Build a find expression like: \( -iname "*.pdf" -o -iname "*.txt" ... \)
build_find_expr() {
  local expr=""
  for ext in "${EXT_ARR[@]}"; do
    [[ -z "$expr" ]] && expr="-iname *.$ext" || expr="$expr -o -iname *.$ext"
  done
  echo "\( $expr \)"
}

FIND_EXPR="$(build_find_expr)"

# ---------- Create staging ----------
TS="$(timestamp)"
BASENAME="$(echo "${ORG}_${LABEL}_${TS}" | tr '[:upper:] ' '[:lower:]_' )"
STAGE_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t airgap_stage)"
STAGE="$STAGE_ROOT/payload"
mkdir -p "$STAGE"

note "Collecting files from: $SRC"
note "Whitelist: ${EXT_ARR[*]} (max ${MAX_SIZE_MB}MB each)"
note "Stage: $STAGE"

# Find eligible files (skip VCS dirs)
# shellcheck disable=SC2016
while IFS= read -r -d '' file; do
  # size filter (in MB)
  size_bytes=$(filesize_bytes "$file")
  if (( size_bytes > MAX_SIZE_MB*1024*1024 )); then
    warn "Skipping (size>${MAX_SIZE_MB}MB): $file"
    continue
  fi

  # compute relative path
  rel="${file#$SRC/}"
  mkdir -p "$STAGE/$(dirname "$rel")"
  cp -p "$file" "$STAGE/$rel"
done < <(find "$SRC" -type f \( $FIND_EXPR \) \
          -not -path "*/.git/*" -not -path "*/.svn/*" -print0)

# ---------- Optional EXIF strip ----------
if [[ $STRIP_EXIF -eq 1 ]]; then
  if have exiftool; then
    note "Stripping EXIF metadata (images)..."
    find "$STAGE" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -print0 \
      | while IFS= read -r -d '' img; do
          exiftool -overwrite_original -all= "$img" >/dev/null 2>&1 || warn "EXIF strip failed: $img"
        done
  else
    warn "exiftool not found; skipping EXIF stripping."
  fi
fi

# ---------- Normalize permissions ----------
note "Normalizing file permissions to 0644..."
find "$STAGE" -type f -exec chmod 0644 {} +

# ---------- Generate manifest ----------
MANIFEST="$STAGE_ROOT/manifest.txt"
note "Generating SHA-256 manifest: $MANIFEST"
{
  echo "# Airgap Bundler Manifest"
  echo "# Org: $ORG"
  echo "# Label: $LABEL"
  echo "# Timestamp: $TS"
  echo "# Hash: sha-256"
  echo "#"
  echo "# Columns: SHA256  SIZE(B)  RELATIVE_PATH"
} > "$MANIFEST"

while IFS= read -r -d '' f; do
  rel="${f#$STAGE/}"
  sz=$(filesize_bytes "$f")
  h=$(sha256_file "$f")
  printf "%s  %s  %s\n" "$h" "$sz" "$rel"
done < <(find "$STAGE" -type f -print0 | sort -z)

# ---------- Optional ClamAV scan ----------
if [[ $RUN_CLAMAV -eq 1 ]]; then
  if have clamscan; then
    note "Running ClamAV scan..."
    set +e
    clamscan -r --infected --no-summary "$STAGE"
    rc=$?
    set -e
    if [[ $rc -eq 1 ]]; then
      die "ClamAV reported infected files. Aborting bundle."
    elif [[ $rc -gt 1 ]]; then
      warn "ClamAV encountered errors (code=$rc); continuing."
    else
      note "ClamAV scan clean."
    fi
  else
    warn "clamscan not found; skipping AV scan."
  fi
fi

# ---------- Bundle notes ----------
NOTES="$STAGE_ROOT/bundle_notes.txt"
cat > "$NOTES" <<EOF
Bundle: $BASENAME
Org: $ORG
Label: $LABEL
Timestamp: $TS

Contents:
- payload/ (files)
- manifest.txt (SHA-256 for each file)
- bundle_notes.txt (this file)

Verification:
  See scripts/airgap-verify.sh in the repo, or the included verifier if present.

Operational Notes:
- This bundle includes only whitelisted file types and sizes as configured at packaging time.
- Image metadata may have been removed if --strip-exif was enabled and exiftool was available.
- If --clamav was enabled and ClamAV was available, the payload was scanned prior to packaging.

EOF

# ---------- Create tar.gz ----------
OUT_TGZ="$OUT/${BASENAME}.tar.gz"
note "Creating bundle: $OUT_TGZ"
tar -C "$STAGE_ROOT" -czf "$OUT_TGZ" payload manifest.txt bundle_notes.txt

# ---------- Optional GPG sign ----------
if [[ $DO_SIGN -eq 1 ]]; then
  if have gpg; then
    [[ -n "$GPG_KEY" ]] || warn "No --gpg-key provided; gpg will use default key."
    note "Signing bundle (detached, ASCII-armored)..."
    if [[ -n "$GPG_KEY" ]]; then
      gpg --batch --yes --local-user "$GPG_KEY" --armor --detach-sign "$OUT_TGZ"
    else
      gpg --batch --yes --armor --detach-sign "$OUT_TGZ"
    fi
    note "Signature: ${OUT_TGZ}.asc"
  else
    warn "gpg not found; skipping signature."
  fi
fi

note "Done."
note "Output: $OUT_TGZ"

