# photo-tools

A collection of photo management tools, grouped into directories by purpose.

## Repository layout

```
photo-tools/
├── README.md                 # this file
├── install/
│   └── install.sh            # copies every tool script into /usr/local/bin
└── workflow/                 # post-shoot workflow: SD card import and file organization
    ├── import_photos.sh      # PRIMARY: import an SD card after a shoot (copy, rename, DNG)
    └── rename_nef.sh         # rename NEFs to capture time (used by import_photos.sh)
```

| Directory   | Purpose                                                            |
|-------------|--------------------------------------------------------------------|
| `install/`  | Installing the tools on a Mac (not a tool itself).                 |
| `workflow/` | Getting photos off the camera and into the archive after a shoot.  |

### Adding new tools

- Put each tool in a top-level directory named for its purpose (e.g. `workflow/`). Create a new directory when a tool doesn't fit an existing one.
- `install/install.sh` picks up every `*.sh` one level down (`<tool-dir>/<name>.sh`) automatically. Script names must be unique across all tool directories, since they're all installed into one folder.
- Keep scripts that call each other in the same directory — `import_photos.sh` finds `rename_nef.sh` by looking next to itself.
- Add the tool to the tree and table above, and give it a section under [Tools](#tools).

---

## Tools

> **Primary workflow:** After a photo shoot, use **`workflow/import_photos.sh`** to process the camera's SD card. It copies files off the card, organizes them by date, renames NEFs by capture time, converts them to DNG, and keeps a manifest so nothing is imported twice. `rename_nef.sh` is called automatically by `import_photos.sh` and can also be used on its own.

### `workflow/import_photos.sh` — Import and organize photos from an SD card

**Workflow:**
1. **Copy** — Every file in the card's DCIM folder is copied (never moved; the card is left untouched) into folders by capture date and file type (`20261017/NEF/`, `20261017/JPG/`, …), and each copy is verified.
2. **Rename** — Newly imported NEFs are renamed to their capture time with `rename_nef.sh`, so they sort chronologically.
3. **Convert** — NEFs are converted with Adobe DNG Converter into the date folder's `DNG/`, named `<YYYYMMDD>-<event>-<nnnnn>.dng` in capture order.
4. **Deduplicate** — A manifest prevents re-importing the same file (e.g. re-inserting a card or importing the camera's backup slot), and byte-identical NEFs are dropped before conversion so a photo never gets two DNGs.

**Usage:**
```bash
workflow/import_photos.sh -e EVENT [options]

Required:
  -e EVENT     event name ("Detroit Riverwalk" -> detroit-riverwalk)

Options:
  -s SOURCE    card mount point (default: the volume in /Volumes that has a DCIM folder)
  -d DEST      destination root (default: /Volumes/photos-01)
  -D YYYYMMDD  put everything in this one date folder instead of sorting by capture date
  -V           verify copies byte-for-byte (default: size check)
  -k           copy and rename only; skip DNG conversion
  -F           force: ignore the manifest and copy everything again
               (identical photos are still never converted twice)
  -x           eject the card when finished
  -n           dry run: show what would happen, change nothing

Environment overrides:
  DNG_CONVERTER  path to the converter binary
                 (default: /Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter)
  DNG_OPTS       converter options (default: "-c -p1" = lossless compressed, medium preview)
```

**Examples:**
```bash
# Preview what will happen
import_photos.sh -e "Detroit Riverwalk" -n

# Import, then eject the card
import_photos.sh -e "Detroit Riverwalk" -x

# Second card from the same shoot: DNG numbering continues where the first card left off
import_photos.sh -e "Detroit Riverwalk" -s /Volumes/BACKUP -x
```

**Resulting archive layout:**
```
/Volumes/photos-01/
├── .photo-import-manifest.tsv     # every file imported so far (prevents re-imports)
├── 20261017/
│   ├── NEF/                       # raw files, renamed to capture time
│   │   ├── 20261017201845.NEF
│   │   └── 2026101720184537.NEF
│   ├── JPG/
│   ├── MOV/
│   └── DNG/                       # converted files, numbered per date + event
│       ├── 20261017-detroit-riverwalk-00001.dng
│       └── 20261017-detroit-riverwalk-00002.dng
└── 20261018/
    └── ...
```

**Tips:**
- Run with `-n` first to preview.
- If an import is interrupted, re-run the same command to finish it.
- Use `-V` for byte-for-byte verification (slower; worthwhile with an unreliable card reader).
- Two events on the same day each get their own DNG number sequence.

---

### `workflow/rename_nef.sh` — Rename NEF files by capture time

Renames Nikon NEF files (and matching `.xmp` sidecars) to `YYYYMMDDHHMMSS[subseconds].NEF` using the EXIF `DateTimeOriginal` and `SubSecTimeOriginal` tags.

```
DSC_0142.NEF -> 20261017201845.NEF      (no subseconds available)
DSC_0143.NEF -> 2026101720184537.NEF    (2026-10-17 20:18:45.37)
```

**Usage:**
```bash
workflow/rename_nef.sh [-n] [-r] DIRECTORY
  -n   dry run: show what would be renamed, change nothing
  -r   recurse into subdirectories
```

If two shots share the exact same subsecond, a `_1`, `_2`, … suffix is added. Files without a capture time are skipped.

---

## Installation (macOS)

### Prerequisites

```bash
brew install exiftool
```

`import_photos.sh` also needs **Adobe DNG Converter** (a free download from Adobe) installed in `/Applications`, or set `DNG_CONVERTER` to its path. Use `-k` to skip DNG conversion if it isn't installed.

### Install to `/usr/local/bin`

Installing the scripts to `/usr/local/bin` lets you run them by name from any directory. Run the installer from anywhere in the repository:

```bash
install/install.sh -n      # preview what will be installed
install/install.sh         # install
```

The installer:
- copies every tool script (currently `import_photos.sh` and `rename_nef.sh`) into `/usr/local/bin`, creating it if needed;
- sets each script to mode `755` (`rwxr-xr-x`): every user can run it, only the owner can change it;
- uses `sudo` only if `/usr/local/bin` isn't writable by you, and asks for your password in that case.

Re-run it after pulling updates; installed copies are replaced. Use `-d DIR` to install somewhere else, e.g. `install/install.sh -d ~/bin`.

### Running from the repository instead

```bash
bash workflow/import_photos.sh -e "My Event"
bash workflow/rename_nef.sh ~/Pictures/some-folder
```

Both scripts work with the stock macOS bash 3.2.
