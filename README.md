# photo-tools

A collection of photo management scripts for photographers using Nikon cameras with SD cards.

## Scripts

### `rename_nef.sh` — Rename NEF files by capture time

Renames Nikon NEF files (and their XMP sidecars) to a sortable timestamp format based on EXIF capture time: `YYYYMMDDHHMMSS[subseconds].NEF`

**Example:**
```
DSC_0142.NEF → 20261017201845.NEF
DSC_0143.NEF → 2026101720184537.NEF  (with subseconds)
```

**Usage:**
```bash
./rename_nef.sh [-n] [-r] DIRECTORY
  -n   dry run (show what would be renamed, don't change anything)
  -r   recurse into subdirectories
```

**Requires:**
- `exiftool` (install via `brew install exiftool` on macOS)

**Features:**
- Reads capture time from EXIF `DateTimeOriginal` and `SubSecTimeOriginal` tags
- Adds `_1`, `_2`, etc. suffix if multiple photos share the same timestamp (rare in fast bursts)
- Renames matching `.xmp` and `.XMP` sidecars alongside NEF files
- Works with macOS bash 3.2+

---

### `import_photos.sh` — Import and organize photos from SD card

A complete photo import workflow: copies files from an SD card to a managed archive, deduplicates, renames NEFs to capture time, converts to Adobe DNG format, and catalogs everything with a manifest.

**Workflow:**
1. **Copy** — Every file from the SD card's DCIM folder is copied to an archive organized by capture date and file type (`20261017/NEF/`, `20261017/JPG/`, etc.)
2. **Rename** — Newly imported NEFs are renamed by capture time using `rename_nef.sh` so they sort chronologically
3. **Convert** — NEFs are batch-converted to DNG format with the event name in the filename: `20261017-detroit-riverwalk-00001.dng`
4. **Deduplicate** — A manifest prevents re-importing the same photo (even from different SD cards or backup slots), and byte-identical duplicates are dropped before conversion

**Usage:**
```bash
./import_photos.sh -e EVENT [options]

Required:
  -e EVENT     event name (e.g., "Detroit Riverwalk" → detroit-riverwalk)

Options:
  -s SOURCE    SD card mount point (default: auto-detect /Volumes/*/DCIM)
  -d DEST      destination root (default: /Volumes/photos-01)
  -D YYYYMMDD  put everything in one date folder instead of by capture date
  -V           verify copies byte-for-byte (default: size check only)
  -k           copy and rename only; skip DNG conversion
  -F           force: ignore manifest and copy everything again
  -x           eject the card when finished
  -n           dry run: show what would happen, change nothing

Environment variables:
  DNG_CONVERTER  path to Adobe DNG Converter
                 (default: /Applications/Adobe\ DNG\ Converter.app/Contents/MacOS/Adobe\ DNG\ Converter)
  DNG_OPTS       converter options (default: "-c -p1" = lossless compressed, medium preview)
```

**Requires:**
- `exiftool` (install via `brew install exiftool` on macOS)
- `rename_nef.sh` in the same directory as `import_photos.sh`
- Adobe DNG Converter (free, from [Adobe](https://helpx.adobe.com/camera-raw/using/adobe-dng-converter.html))

**Features:**
- Auto-detects SD card (looks for `/Volumes/*/DCIM`)
- Imports from multiple cards for the same date/event (DNG numbering continues)
- Deduplication via manifest and byte-comparison prevents duplicates
- Resumes interrupted imports
- Dry-run mode to preview changes
- Free-space checking before copying
- Works with macOS bash 3.2+

**Example workflow:**
```bash
# Dry run to see what will happen
./import_photos.sh -e "Detroit Riverwalk" -n

# Import for real
./import_photos.sh -e "Detroit Riverwalk" -x

# Import from second backup card, continue numbering
./import_photos.sh -e "Detroit Riverwalk" -s /Volumes/BACKUP -x
```

---

## Installation

### macOS / OS X

Copy the scripts to `/usr/local/bin` to use them from anywhere:

```bash
# From the photo-tools directory
cp rename_nef.sh /usr/local/bin/
cp import_photos.sh /usr/local/bin/
chmod +x /usr/local/bin/rename_nef.sh /usr/local/bin/import_photos.sh
```

Then use them from anywhere:
```bash
rename_nef.sh ~/Photos/
import_photos.sh -e "My Event"
```

Or run them directly from this repository:
```bash
./rename_nef.sh ~/Photos/
./import_photos.sh -e "My Event"
```

### Linux

The scripts are portable and work on Linux with bash 3.2+, exiftool, and GNU/BSD stat. Note that `import_photos.sh` uses `/Volumes` for mount points (macOS convention); on Linux, adjust the `-s` and `-d` paths to point to your SD card and archive locations.

---

## Prerequisites

### macOS
```bash
# Install exiftool via Homebrew
brew install exiftool

# Download and install Adobe DNG Converter
# Visit: https://helpx.adobe.com/camera-raw/using/adobe-dng-converter.html
```

### Linux (Debian/Ubuntu)
```bash
sudo apt install libimage-exiftool-perl
# Then install Adobe DNG Converter or use an alternative (e.g., rawtoaces, dcraw)
```

---

## Folder Structure

After importing with `import_photos.sh`, your archive looks like:

```
/Volumes/photos-01/
├── 20261017/
│   ├── NEF/               # Nikon raw files (renamed by capture time)
│   │   ├── 20261017201845.NEF
│   │   └── 2026101720184537.NEF
│   ├── JPG/               # JPEG previews from camera
│   ├── MOV/               # Videos
│   └── DNG/               # Adobe DNG conversions (one per event)
│       ├── 20261017-detroit-riverwalk-00001.dng
│       └── 20261017-detroit-riverwalk-00002.dng
├── 20261018/
│   ├── NEF/
│   └── DNG/
└── .photo-import-manifest.tsv  # Manifest (prevents re-importing)
```

---

## Tips

- **Safe re-insertion:** The manifest remembers every imported file. If you re-insert a card, only new photos are copied.
- **Backup card workflow:** If your camera has two SD slots, import from the main card first, then the backup. DNG numbering continues automatically.
- **Verify copies:** Use `-V` to verify byte-for-byte (slower but safer over unreliable USB connections).
- **Dry run first:** Always use `-n` first to preview what will happen.
- **Interrupted imports:** If an import is interrupted, re-run the same command to resume and finish.
