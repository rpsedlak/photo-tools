# photo-tools

A collection of photo management tools, grouped into directories by purpose.

> **Production location:** In normal use the tools are installed with `install/install.sh` and run from **`/usr/local/bin`**, by name (e.g. `import_photos.sh -e "My Event"`). The exception is when they were installed somewhere else with `install/install.sh -d DIR`; then they run from that folder. This repository is the source; the `workflow/...` paths below show where each script lives in the repo, not where it runs from.

## Repository layout

```
photo-tools/
├── README.md                 # this file
├── install/
│   ├── install.sh            # installs prerequisites, then copies every tool script into /usr/local/bin
│   └── prereqs.sh            # checks for / installs required tools (via Homebrew)
├── workflow/                 # post-shoot workflow: SD card import and file organization
│   ├── import_photos.sh      # PRIMARY: import an SD card after a shoot (copy, rename, DNG)
│   └── rename_nef.sh         # rename NEFs/JPGs to capture time (used by import_photos.sh)
└── cloud/                    # cloud backup and sharing
    └── upload_azure.sh       # upload folders to Azure Blob containers, with a retry folder for failures
```

| Directory   | Purpose                                                            |
|-------------|--------------------------------------------------------------------|
| `install/`  | Installing the tools on a Mac (not a tool itself).                 |
| `workflow/` | Getting photos off the camera and into the archive after a shoot.  |
| `cloud/`    | Copying photos to cloud storage.                                   |

### Adding new tools

- Put each tool in a top-level directory named for its purpose (e.g. `workflow/`). Create a new directory when a tool doesn't fit an existing one.
- `install/install.sh` picks up every `*.sh` one level down (`<tool-dir>/<name>.sh`) automatically. Script names must be unique across all tool directories, since they're all installed into one folder.
- Keep scripts that call each other in the same directory — `import_photos.sh` finds `rename_nef.sh` by looking next to itself.
- If a new tool needs another program, add a check for it to `install/prereqs.sh`.
- Add the tool to the tree and table above, and give it a section under [Tools](#tools).

---

## Tools

> **Primary workflow:** After a photo shoot, use **`workflow/import_photos.sh`** to process the camera's SD card. It copies files off the card, organizes them by date, renames NEFs and JPGs by capture time, converts them to DNG, and keeps a manifest so nothing is imported twice. `rename_nef.sh` is called automatically by `import_photos.sh` and can also be used on its own.

### `workflow/import_photos.sh` — Import and organize photos from an SD card

**Workflow:**
1. **Copy** — Every file in the card's DCIM folder is copied (never moved; the card is left untouched) into folders by capture date and file type (`20261017/NEF/`, `20261017/JPG/`, …), and each copy is verified. Each date folder also gets an empty `prod/` folder next to `NEF/` and `DNG/`; if `prod/` already exists it is left exactly as it is.
2. **Rename** — Newly imported NEFs and JPGs are renamed to their capture time with `rename_nef.sh`, so they sort chronologically. Other types (MOV, …) keep their camera names.
3. **Convert** — NEFs are converted with Adobe DNG Converter into the date folder's `DNG/`, named `<YYYYMMDD>-<event>-<nnnnn>.dng` in capture order.
4. **Copyright** — If a copyright owner is set (see [Copyright](#copyright)), each new DNG is stamped `© <year> <owner>`, with the year taken from that photo's capture date. NEFs are never modified.
5. **Deduplicate** — A manifest prevents re-importing the same file (e.g. re-inserting a card or importing the camera's backup slot), and byte-identical NEFs and JPGs are dropped before filing, so a photo is never stored twice or given two DNGs.

**RAW+JPEG shots:** when the camera records both `DSC_0001.NEF` and `DSC_0001.JPG` for the same picture, both are copied, to `NEF/` and `JPG/`, and both are renamed to the same capture time (e.g. `NEF/2026101710000050.NEF` and `JPG/2026101710000050.JPG`), so the pair is easy to match up. Only NEFs are ever converted, so the DNG always comes from the NEF; the JPG is kept as-is, and JPEG-only shots get no DNG.

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
│   ├── JPG/                       # JPEGs, renamed the same way (a RAW+JPEG pair shares a name)
│   │   └── 2026101720184537.JPG
│   ├── MOV/                       # other types keep their camera names
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
- Long steps show a live status line: files done out of the total, plus amount copied, elapsed time and estimated time left while copying and converting. When the output is redirected to a log file, a progress line is written every 10% instead.
- If an import is interrupted, re-run the same command to finish it.
- Use `-V` for byte-for-byte verification (slower; worthwhile with an unreliable card reader).
- Two events on the same day each get their own DNG number sequence.

---

### `workflow/rename_nef.sh` — Rename NEF (or JPG) files by capture time

Renames Nikon NEF files (and matching `.xmp` sidecars) to `YYYYMMDDHHMMSS[subseconds].NEF` using the EXIF `DateTimeOriginal` and `SubSecTimeOriginal` tags. With `-e jpg` it renames JPGs the same way. That's how `import_photos.sh` gives both files of a RAW+JPEG shot the same name.

```
DSC_0142.NEF -> 20261017201845.NEF      (no subseconds available)
DSC_0143.NEF -> 2026101720184537.NEF    (2026-10-17 20:18:45.37)
DSC_0143.JPG -> 2026101720184537.JPG    (with -e jpg)
```

**Usage** (installed in `/usr/local/bin`):
```bash
rename_nef.sh [-n] [-r] [-e EXT] DIRECTORY
  -n       dry run: show what would be renamed, change nothing
  -r       recurse into subdirectories
  -e EXT   rename files with this extension instead of NEF, e.g. -e jpg
           (matches upper and lower case; the extension's case is kept)
```

If two shots share the exact same subsecond, a `_1`, `_2`, … suffix is added. Files without a capture time are skipped.

---

### `cloud/upload_azure.sh` — Upload photo folders to Azure Blob Storage

Uploads local folders into Azure Blob Storage containers, one container per category (e.g. `charlevoix`, `grand-haven`), using `azcopy`. Uploads can take hours, so files that fail are moved to a retry folder, and a retry run only uploads those files.

**Workflow:**
1. **Sign in** — as you (your existing `az login`) or as a service principal (`-I sp`, see [Service principal setup](#service-principal-setup)).
2. **Check** — before anything is uploaded, every container is checked: it must exist and the signed-in identity must have access. Problems stop the run with a message naming the missing role.
3. **Authorize azcopy** — by default the script creates a short-lived **user delegation SAS** for each container. The SAS is signed with your Entra ID sign-in, never with storage account keys, so account keys can stay disabled. It allows only read/create/write/list, never delete, and is HTTPS-only and never printed or logged. With `-A oauth`, azcopy signs in itself instead and renews its own tokens. That suits very long uploads, which could outlast a SAS.
4. **Upload** — every file under each folder goes to its container (see [Where files go in the container](#where-files-go-in-the-container)):
   - Each first-level subfolder becomes a folder in the container, keeping everything below it.
   - Files sitting directly in the folder go into a `general/` folder.
   - Hidden files and folders (`.DS_Store`, `.incoming/`, …) are skipped.
   - Blobs that are already in the container are skipped, so re-running only sends what is new.
   - Each blob gets an MD5 hash.
   - azcopy uploads in 40 MiB blocks (`--block-size-mb=40`) with no bandwidth cap (`--cap-mbps=0`).
5. **Report and retry** — at the end, every file that could not be uploaded is listed with the reason. A symbolic link to it is created in the retry folder, keeping its folder structure, and its original path is recorded in `retry-manifest.tsv`. The original stays in place.
   - Run the same command with **`-R`** to upload only the retry folder.
  - Each retried file that succeeds has its retry link removed.
   - A file whose name is already taken in the container by a *different* file (different size) counts as a failure, and the existing blob is never replaced unless you use `-O`.

**Usage** (installed in `/usr/local/bin`):
```bash
upload_azure.sh -a ACCOUNT -u CONTAINER=DIR [-u CONTAINER=DIR ...] [options]

  -a ACCOUNT    storage account name, e.g. rpsphotography001 (default: $PHOTO_AZ_ACCOUNT)
  -u C=DIR      upload folder DIR into container C (repeat for each category)
  -m MAPFILE    read CONTAINER=DIR (or CONTAINER<TAB>DIR) lines from a file
  -p PREFIX     optional extra folder in front of everything uploaded, e.g. 2026
  -r RETRY      retry folder root (default: $PHOTO_UPLOAD_RETRY, else DIR/.upload-retry)
  -R            retry mode: upload only what is in the retry folders
  -I user|sp    who signs in: user = your az login, sp = a service principal (default: user)
  -i APP_ID     service principal application (client) ID
  -z TENANT     Entra tenant ID
  -K PEM        service principal certificate (PEM with private key + certificate)
  -A sas|oauth  azcopy uses a SAS this script creates, or signs in itself (default: sas)
  -t HOURS      SAS lifetime, 1-167 (default 24)
  -T TIER       blob tier: Hot, Cool, Cold or Archive (default: the account's)
  -O            replace a blob when the local file is newer (default: never replace)
  -n            dry run: sign in and check access, show what would be uploaded
  -v            verbose: show settings, every az/azcopy command and full errors (for debugging)
```

Exit status: `0` everything uploaded (or already there), `2` some files failed and were moved to the retry folder, `1` error (nothing uploaded).

**Choosing the storage account (`-a` / `PHOTO_AZ_ACCOUNT`):** this is the *name* of the Azure storage account that holds your category containers. It's the first part of the account's blob address `https://<name>.blob.core.windows.net`. Storage account names are 3–24 lowercase letters and digits and are unique across all of Azure. Use the bare name, not the URL, the resource group, or a container name. To find it:
```bash
# every storage account you can see, with its resource group
az storage account list --query '[].{name:name, group:resourceGroup, location:primaryLocation}' -o table

# check it's the right one: list its containers (these are your categories)
az storage container list --account-name rpsphotography001 --auth-mode login --query '[].name' -o tsv
```
Or in the Azure portal: **Storage accounts** → the account → its name is the page title. Set it once in `~/.zshrc` so you don't need `-a` each time:
```bash
export PHOTO_AZ_ACCOUNT=rpsphotography001
```

**Choosing who signs in (`-I` / `PHOTO_AZ_AUTH`):** this picks the Azure identity the script signs in as, which is also the identity Azure checks for permission to upload. If it's not set, `user` is used.

| Value  | Signs in as | Use it when | Setup needed |
|--------|-------------|-------------|--------------|
| `user` | **You**, reusing your existing `az login` (run `az login` once; it lasts for weeks). | You run uploads yourself from your own Mac. The simplest choice. | Give your account the *Storage Blob Data Contributor* role (see [Access requirements](#access-requirements-rbac)). |
| `sp`   | A **service principal**: an app identity with its own certificate or client secret. It signs in separately, so your own `az login` is left alone. | Uploads run unattended (a scheduled job, another Mac), or you want an identity that can *only* upload photos, not use your full account. | Create the service principal and set `PHOTO_AZ_CLIENT_ID`, `PHOTO_AZ_TENANT_ID` and a certificate or secret (see [Service principal setup](#service-principal-setup)). |

Being *Owner* of the subscription is not enough for either one: Owner manages the account but can't read or write blobs. The pre-upload check (and `-n`) reports this before anything is uploaded.

**Where files go in the container:** inside each container, every first-level subfolder of the source folder keeps its name. Files directly in the source folder (not in a subfolder) go into a folder called `general`, which is created the first time and added to after that. For `-u grand-haven=~/Export/GrandHaven`:

| Local file                                  | Blob in `grand-haven`        | With `-p 2026`                    |
|---------------------------------------------|------------------------------|-----------------------------------|
| `~/Export/GrandHaven/20261017/DNG/a.dng`    | `20261017/DNG/a.dng`         | `2026/20261017/DNG/a.dng`         |
| `~/Export/GrandHaven/sunsets/b.jpg`         | `sunsets/b.jpg`              | `2026/sunsets/b.jpg`              |
| `~/Export/GrandHaven/c.jpg`                 | `general/c.jpg`              | `2026/general/c.jpg`              |

`-p` is optional: it adds the same extra folder (it can have several levels, e.g. `2026/fall`) in front of every blob. Without it, the subfolders and `general/` sit at the top of the container.

- The dry run (`-n`) lists each file with the blob it will become.
- If the source folder has a subfolder that is itself called `general`, its files go to `general/` too. A loose file with the same name as one in that subfolder would land on the same blob, so the script stops before uploading and lists those files.

**Examples:**
```bash
# Preview: signs in, checks both containers, lists each file and the blob it becomes
upload_azure.sh -a rpsphotography001 -u charlevoix=~/Export/charlevoix -u grand-haven=~/Export/grand-haven -n

# Upload
upload_azure.sh -a rpsphotography001 -u charlevoix=~/Export/charlevoix -u grand-haven=~/Export/grand-haven

# Same, but under a 2026/ folder in each container
upload_azure.sh -a rpsphotography001 -u charlevoix=~/Export/charlevoix -u grand-haven=~/Export/grand-haven -p 2026

# Some files failed: fix the cause, then upload only those
upload_azure.sh -a rpsphotography001 -u charlevoix=~/Export/charlevoix -u grand-haven=~/Export/grand-haven -R

# Categories kept in a file (one CONTAINER=DIR per line, # comments allowed)
upload_azure.sh -a rpsphotography001 -m ~/photo-categories.txt
```

**Retry folder layout** (default: inside each source folder; links are hidden from normal uploads):
```
~/Export/grand-haven/
├── 20261017/...                               # files that uploaded stay where they were
└── .upload-retry/
    ├── retry-manifest.tsv                     # container, blob, original path, time, identity, error
    └── grand-haven/                           # links, one per failed blob path
        ├── 2026/20261017/DNG/a.dng -> ~/Export/grand-haven/20261017/DNG/a.dng
        └── 2026/general/c.jpg -> ~/Export/grand-haven/c.jpg
```
Each run also writes `report.txt` (every failure and where the file is now) and azcopy's logs to `~/.photo-tools/upload-runs/<date-time>/` (change it with `PHOTO_UPLOAD_LOGS`).

#### Access requirements (RBAC)

Whoever signs in, you or a service principal, needs this Azure role on the storage account, or on each container you upload to:

| Role                              | Why                                                                   |
|-----------------------------------|-----------------------------------------------------------------------|
| **Storage Blob Data Contributor** | Check the containers, create the user delegation SAS, upload blobs.   |

`Owner` or `Contributor` on the subscription are **not** enough on their own, because they don't include data access. Assign the role (you need *Owner*, *User Access Administrator* or *Role Based Access Control Administrator* to do this):

```bash
ACCOUNT_ID=$(az storage account show -n rpsphotography001 -g rg-photography --query id -o tsv)
az role assignment create --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "Storage Blob Data Contributor" --scope "$ACCOUNT_ID"
```

- New role assignments can take up to 10 minutes to start working.
- The containers must already exist; the script never creates them.
- If the storage account has a firewall, your public IP must be allowed.
- Storage account keys (shared key access) are never used and can stay disabled.

#### Service principal setup

A service principal lets the upload run under its own identity instead of yours, for example from a scheduled job or a dedicated Mac. You need:

1. **Permission to create it** — creating an app registration in the tenant (the *Application Developer* role, or app registration left open to users), plus the right to assign roles on the storage account (see above).
2. **The service principal, limited to the storage account** (or to one container, using the container's ID `$ACCOUNT_ID/blobServices/default/containers/<name>` as the scope; repeat `az role assignment create` for each container). A certificate is preferred to a client secret:
   ```bash
   az ad sp create-for-rbac --name photo-tools-uploader \
     --role "Storage Blob Data Contributor" --scopes "$ACCOUNT_ID" \
     --create-cert          # leave out for a client secret (add --years N to set its lifetime)
   ```
   Note the `appId` and `tenant` in the output. With `--create-cert`, the output also gives the path of a PEM file holding the private key and certificate. Don't grant *Contributor* or *Owner*.
3. **Store the credential:**
   - **Certificate (recommended):** move the PEM to `~/.photo-tools/` and run `chmod 600` on it. The script warns if other users can read it. It must be unencrypted (no passphrase).
   - **Client secret:** keep it in the macOS Keychain, where `security` prompts for the secret so it never appears on screen or in shell history:
     ```bash
     security add-generic-password -s photo-tools-azure -a <appId> -w
     ```
     Or export `PHOTO_AZ_CLIENT_SECRET` (or `AZURE_CLIENT_SECRET`) only in the shell where you run the upload. Don't put a secret in `~/.zshrc`. There is deliberately no command-line option for the secret, because command lines show up in `ps` and shell history.
4. **Settings in `~/.zshrc`** (none of these are secret):
   ```bash
   export PHOTO_AZ_ACCOUNT=rpsphotography001
   export PHOTO_AZ_AUTH=sp
   export PHOTO_AZ_CLIENT_ID=<appId>
   export PHOTO_AZ_TENANT_ID=<tenant>
   export PHOTO_AZ_CERT_PATH=~/.photo-tools/photo-tools-uploader.pem   # if using a certificate
   ```
   Then `upload_azure.sh -u grand-haven=~/Export/grand-haven` signs in as the service principal. Command-line options override these variables.
5. **Renew before it expires** — secrets and certificates expire (one year by default). When sign-in fails because of that, the script says so. Renew with `az ad sp credential reset --id <appId> [--create-cert]`.

**Every setting and where it comes from** (an option beats a `PHOTO_*` variable, which beats the standard `AZURE_*` variable):

| Setting                | Option | Environment variables                                       | Default              |
|------------------------|--------|-------------------------------------------------------------|----------------------|
| Who signs in           | `-I`   | `PHOTO_AZ_AUTH`                                             | `user`               |
| App (client) ID        | `-i`   | `PHOTO_AZ_CLIENT_ID`, `AZURE_CLIENT_ID`                     | —                    |
| Tenant ID              | `-z`   | `PHOTO_AZ_TENANT_ID`, `AZURE_TENANT_ID`                     | —                    |
| Certificate            | `-K`   | `PHOTO_AZ_CERT_PATH`, `AZURE_CLIENT_CERTIFICATE_PATH`       | —                    |
| Client secret          | —      | `PHOTO_AZ_CLIENT_SECRET`, `AZURE_CLIENT_SECRET`, then Keychain | —                 |
| Keychain item          | —      | `PHOTO_AZ_KEYCHAIN_SERVICE`                                 | `photo-tools-azure`  |
| Storage account name   | `-a`   | `PHOTO_AZ_ACCOUNT`                                          | —                    |
| azcopy authorization   | `-A`   | `PHOTO_AZ_TRANSFER`                                         | `sas`                |
| Retry folder root      | `-r`   | `PHOTO_UPLOAD_RETRY`                                        | `DIR/.upload-retry`  |
| Reports and logs       | —      | `PHOTO_UPLOAD_LOGS`                                         | `~/.photo-tools/upload-runs` |
| Verbose output         | `-v`   | `PHOTO_UPLOAD_VERBOSE=1`                                    | off                  |

If both a certificate and a secret are set, the certificate is used.

**How the service principal is used:**
- The script signs it in with a private, temporary Azure CLI profile (`AZURE_CONFIG_DIR`), deleted when the script ends. Your own `az login` and default subscription are left untouched.
- With `-A oauth`, azcopy signs in as the service principal itself, using its `AZCOPY_SPA_*` variables. These are set only for the azcopy process.

**Tips:**
- Run with `-n` first. It signs in and checks every container, so a missing role or wrong ID shows up before a long upload starts.
- **Debugging:** add `-v` (or set `PHOTO_UPLOAD_VERBOSE=1`) to see what the script is doing. Lines starting with `debug` go to stderr and show:
  - every setting and where it came from (option, environment variable, or default), plus tool versions;
  - each `az`/`azcopy` command as it runs, with its exit code and how long it took;
  - the full error text from `az`, not just the first lines;
  - azcopy's job ID and log file, and how many files ended in each transfer status.

  azcopy also logs at INFO level instead of WARNING. Besides `report.txt` and azcopy's `logs/`, the run folder keeps:
  - `debug.log`: the same debug lines;
  - `outcome-N-<container>.tsv`: each file's size, outcome, azcopy status and HTTP code;
  - `plans/`: azcopy's job plans, so `AZCOPY_JOB_PLAN_LOCATION=<run folder>/plans azcopy jobs show <job ID>` still works afterwards.

  SAS signatures and client secrets are always shown as `REDACTED`/`<hidden>`. With `-n`, debug lines are only shown on screen, since a dry run writes no files.
- If every file fails at once, the cause is usually the network, the account firewall, a missing role, or an expired SAS. The script says so and points at the azcopy log.
- For uploads that may run longer than the SAS lifetime (`-t`, at most 167 hours), use `-A oauth`.
- Ctrl-C stops the upload without moving anything to the retry folder. Re-run the same command; files that already made it are skipped.
- A SAS is passed to azcopy on its command line, so other users on the same Mac could briefly see it with `ps`. It only works on one container, can't delete anything, and expires. A client secret given to `az login` is exposed the same way for a moment. A certificate, or `-A oauth`, avoids both.

---

## Installation (macOS)

### Prerequisites

| Tool                | Needed by                          | Installed by `prereqs.sh` with           |
|---------------------|------------------------------------|------------------------------------------|
| Homebrew            | installing the tools below         | — (install it yourself from https://brew.sh) |
| exiftool            | `import_photos.sh`, `rename_nef.sh` | `brew install exiftool`                  |
| Adobe DNG Converter | `import_photos.sh`                 | `brew install --cask adobe-dng-converter` (macOS 14+) |
| Azure CLI           | `upload_azure.sh`                  | `brew install azure-cli`                 |
| azcopy              | `upload_azure.sh`                  | `brew install azcopy`                    |
| jq                  | `upload_azure.sh`                  | included with macOS 15+, else `brew install jq` |

`install/install.sh` requires `cloud/upload_azure.sh`, checks and installs missing prerequisites first, then copies the tool scripts. Azure CLI, azcopy, and jq are required to run `upload_azure.sh`. To check or install prerequisites on their own:

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
- copies every tool script (currently `import_photos.sh`, `rename_nef.sh` and `upload_azure.sh`) into `/usr/local/bin`, creating it if needed;
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
