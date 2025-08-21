# Airgap-Bundler

Secure file packaging for air-gapped defense environments (with manifests, EXIF stripping, optional AV scan, and verification).

> This helper does not replace your program’s data-handling policy. Always follow local SOPs, AO guidance, and classification rules.

---

## Why I Built This

In defense programs, moving data across boundaries (e.g., from an unclassified network into a lab or SCIF) demands discipline:
- Minimize content
- Strip metadata
- Document exactly what moved
- Make it verifiable and repeatable

This repo provides a hardened, scriptable way to do exactly that.

---

## What This Tool Does

- **Collects only approved file types** from a source directory  
- **Strips image metadata (EXIF)** when possible  
- **Normalizes permissions** to reduce risk  
- **Creates a SHA-256 manifest** of every file in the bundle  
- **Optionally scans with ClamAV** if available  
- **Optionally signs the bundle with GPG** for provenance  
- **Emits a verifier flow** to re-check integrity on the receiving side

---

## Requirements

- **Core:** `bash`, `tar`, `gzip`, `find`
- **Hash:** `sha256sum` **or** `shasum -a 256` (macOS)
- **Optional:**
  - `exiftool` (strip metadata)
  - `clamscan` (ClamAV AV scan)
  - `gpg` (detached signature)

---

## Quick Start

```bash
# Make scripts executable
chmod +x scripts/airgap-bundler.sh scripts/airgap-verify.sh

# Package a source folder
./scripts/airgap-bundler.sh \
  --src ./my_workspace/export_candidate \
  --out ./dist \
  --org "BlueTeamLab" \
  --label "UNCLASSIFIED" \
  --include-ext "pdf,txt,csv,json,xml,yaml,yml,md,png,jpg,jpeg,gif" \
  --max-size-mb 50 \
  --strip-exif \
  --clamav

# Verify after transfer (point to extracted bundle dir or tarball)
./scripts/airgap-verify.sh ./dist/<extracted_dir>
# or
./scripts/airgap-verify.sh --tar ./dist/<bundle>.tar.gz
```

## What I learned

- Air-gap discipline is about reduction. Whitelisting file types and sizes does more for safety than complex blacklists.
- Reproducibility builds trust. A signed manifest and a deterministic packaging flow make reviews and audits simpler.
- Cross-platform nuisances matter. sha256sum vs shasum -a 256, stat differences (Linux vs macOS), and optional tools availability all require graceful fallbacks.

## Issues I hit and how I resolved them
- Different hash tools on macOS vs Linux
  Resolution: Auto-detect and use whichever is available.
- stat output differences (size detection)
  Resolution: Try GNU stat first, fallback to BSD stat.
- Optional tools not installed (exiftool, clamscan, gpg)
  Resolution: Treat them as best-effort features; warn and continue without failing the core bundle.
- Preserving relative paths from find
  Resolution: Build paths relative to --src and recreate directory structure on copy.

## Future improvements

- SBOM generation (e.g., syft) for code or container payloads
- Templated policy gates per classification level
- JSON manifest + signature envelope


