# photo-tools

A collection of photo management tools, grouped into directories by purpose.

> **Production location:** In normal use the tools are installed with `install/install.sh` and run from **`/usr/local/bin`**, by name (e.g. `import_photos.sh -e "My Event"`). The exception is when they were installed somewhere else with `install/install.sh -d DIR`; then they run from that folder. This repository is the source; the `workflow/...` paths below show where each script lives in the repo, not where it runs from.

## Repository layout

```
photo-tools/
├── README.md                 # this file
├── install/
│   ├── install.sh            # installs prerequisites, then copies every tool script into /usr/local/bin
│   └── prereqs.sh            # checks for / installs exiftool and Adobe DNG Converter (via Homebrew)
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
- If a new tool needs another program, add a check for it to `install/prereqs.sh`.
- Add the tool to the tree and table above, and give it a section under [Tools](#tools).

---

## Tools

> **Primary workflow:** After a photo shoot, use **`workflow/import_photos.sh`** to process the camera's SD card. It copies files off the card, organizes them by date, renames NEFs by capture time, converts them to DNG, and keeps a manifest so nothing is imported twice. `rename_nef.sh` is called automatically by `import_photos.sh` and can also be used on its own.

### `workflow/import_photos.sh` — Import and organize photos from an SD card

**Workflow:**
1. **Copy** — Every file in the card's DCIM folder is copied (never moved; the card is left untouched) into folders by capture date and file type (`20261017/NEF/`, `20261017/JPG/`, …), and each copy is verified. Each date folder also gets an empty `prod/` folder next to `NEF/` and `DNG/`; if `prod/` already exists it is left exactly as it is.
2. **Rename** — Newly imported NEFs are renamed to their capture time with `rename_nef.sh`, so they sort chronologically.
3. **Convert** — NEFs are converted with Adobe DNG Converter into the date folder's `DNG/`, named `<YYYYMMDD>-<event>-<nnnnn>.dng` in capture order.
4. **Copyright** — If a copyright owner is set (see [Copyright](#copyright)), each new DNG is stamped `© <year> <owner>`, with the year taken from that photo's capture date. NEFs are never modified.
5. **Deduplicate** — A manifest prevents re-importing the same file (e.g. re-inserting a card or importing the camera's backup slot), and byte-identical NEFs are dropped before conversion so a photo never gets two DNGs.

**Usage** (installed in `/usr/local/bin`):
```bash
import_photos.sh -e EVENT [options]

Required:
  -e EVENT     event name ("Detroit Riverwalk" -> detroit-riverwalk)

Options:
  -c OWNER     copyright owner written into each new DNG, e.g. "Richard Sedlak"
               (default: $PHOTO_COPYRIGHT_OWNER; no copyright if neither is set)
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
  PHOTO_COPYRIGHT_OWNER  default copyright owner (same as -c)
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
│   ├── DNG/                       # converted files, numbered per date + event
│   │   ├── 20261017-detroit-riverwalk-00001.dng
│   │   └── 20261017-detroit-riverwalk-00002.dng
│   └── prod/                      # created empty; never written to by the script
└── 20261018/
    └── ...
```

#### Copyright

Set your name once in `~/.zshrc` so every import stamps it automatically:

```bash
export PHOTO_COPYRIGHT_OWNER="Richard Sedlak"
```

`-c "Name"` overrides it for a single import. For a photo captured 2026-10-17, each new DNG gets:

| Tag                                       | Value                    |
|-------------------------------------------|--------------------------|
| EXIF `Copyright`, XMP `dc:rights`         | `© 2026 Richard Sedlak`  |
| EXIF `Artist`, XMP `dc:creator`           | `Richard Sedlak`         |
| XMP `xmpRights:Marked`                    | `True` (copyrighted)     |

These are the fields Lightroom shows as Copyright, Creator and Copyright Status. IPTC copyright and by-line are updated as well if the file already has IPTC data. The year comes from each photo's capture date, so a New Year's Eve shoot is split between the two years correctly.

- Only DNGs are stamped. The NEFs stay byte-for-byte as they came off the card, and with `-k` (no DNGs) nothing is stamped.
- Only DNGs created by this import are stamped. DNGs imported earlier are left as they are.
- Any copyright the camera wrote (Nikon's *Copyright information* setting) is replaced in the DNG by the `-c` owner.
- If stamping fails, those NEFs are not filed and a re-run retries them, just like a failed conversion.

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

**Usage** (installed in `/usr/local/bin`):
```bash
rename_nef.sh [-n] [-r] DIRECTORY
  -n   dry run: show what would be renamed, change nothing
  -r   recurse into subdirectories
```

If two shots share the exact same subsecond, a `_1`, `_2`, … suffix is added. Files without a capture time are skipped.

---

## Installation (macOS)

### Prerequisites

| Tool                | Needed by                          | Installed by `prereqs.sh` with           |
|---------------------|------------------------------------|------------------------------------------|
| Homebrew            | installing the tools below         | — (install it yourself from https://brew.sh) |
| exiftool            | `import_photos.sh`, `rename_nef.sh` | `brew install exiftool`                  |
| Adobe DNG Converter | `import_photos.sh`                 | `brew install --cask adobe-dng-converter` (macOS 14+) |

`install/install.sh` checks these first, so you normally don't need to do anything separately. To check or install them on their own:

```bash
install/prereqs.sh -n      # check only: report what's missing
install/prereqs.sh         # install anything missing
```

- Adobe's DNG Converter installer asks for your password.
- If exiftool is installed but not on your `PATH`, the script says so and shows the line to add to `~/.zprofile`.
- If DNG Converter lives somewhere other than `/Applications`, set `DNG_CONVERTER` to its path; both `prereqs.sh` and `import_photos.sh` use it.
- Without DNG Converter, `import_photos.sh -k` still works (it copies and renames but makes no DNGs).

### Install to `/usr/local/bin`

`/usr/local/bin` is the standard production location for these tools. It is on the default macOS `PATH`, so installed tools run by name from any directory. Run the installer from the repository:

```bash
install/install.sh -n      # preview: report missing prerequisites, show what will be installed
install/install.sh         # install
```

The installer:
- runs `install/prereqs.sh` to install any missing prerequisites, and stops if one can't be installed;
- copies every tool script (currently `import_photos.sh` and `rename_nef.sh`) into `/usr/local/bin`, creating it if needed;
- sets each script to mode `755` (`rwxr-xr-x`): every user can run it, only the owner can change it;
- uses `sudo` only if `/usr/local/bin` isn't writable by you, and asks for your password in that case.

Re-run it after pulling updates; installed copies are replaced. Until you do, `/usr/local/bin` keeps running the older versions.

### Installing to another path

Use `-d DIR` to install somewhere other than `/usr/local/bin`, e.g. `install/install.sh -d ~/bin`. The tools then run from that folder instead. Make sure it is on your `PATH`; the installer warns if it isn't. Install all scripts to the same folder, since `import_photos.sh` needs `rename_nef.sh` next to it.

### Running from the repository (development)

For testing changes before installing them, run the scripts directly from the repository:

```bash
bash workflow/import_photos.sh -e "My Event"
bash workflow/rename_nef.sh ~/Pictures/some-folder
```

Both scripts work with the stock macOS bash 3.2.
