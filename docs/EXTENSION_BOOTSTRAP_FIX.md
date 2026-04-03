# HighBeam Extension Bootstrap Fix (v0.6.8)

## Problem Statement

The HighBeam server browser extension was not loading in BeamNG.drive, resulting in:
```
59.554|E|GELua.extensions|extension unavailable: "highbeam" at location: "highbeam"
59.557|E|GELua.ui_console.exec|Error: ... attempt to index field 'highbeam' (a nil value)
```

The extension could not be opened via console command or in-game menu.

---

## Root Cause Analysis

### The Issue

The **launcher was creating a ZIP file** (`highbeam-client.zip`) and placing it directly in `BeamNG.drive/mods/`, but **BeamNG does not auto-extract ZIP files**.

BeamNG's mod loading system expects:
```
BeamNG.drive/mods/
├── modname/                    ← Directory (NOT a ZIP file)
│   ├── scripts/
│   │   └── modScript.lua       ← Mod entry point
│   └── lua/
│       └── ge/
│           └── extensions/
│               └── highbeam.lua ← GE extension file
```

### What Was Happening

```
BeamNG.drive/mods/
└── highbeam-client.zip        ❌ ZIP file - BeamNG can't read this!
```

When modScript.lua called `extensions.load("highbeam")`, BeamNG tried to find:
- File: `BeamNG.drive/mods/highbeam-client.zip/lua/ge/extensions/highbeam.lua`
- Result: NOT FOUND (ZIP is opaque to the extension loader)

### The Chain of Failures

1. **Installer phase**: `launcher/src/installer.rs` → `install_highbeam_client_mod()`
   - Created ZIP: `highbeam-client.zip` ✗
   - Did NOT extract to directory ✗

2. **Game load phase**: BeamNG reads `mods/` directory
   - Scanned for mod folders
   - Found `highbeam-client.zip` but treated it as a file
   - Never executed modScript.lua ✗

3. **Extension phase**: GE Lua extension system
   - modScript.lua never ran (because BeamNG didn't recognize mod)
   - Even if it ran, `extensions.load("highbeam")` couldn't find the file inside the ZIP

---

## Solution Implemented

### Code Changes

**File**: `launcher/src/installer.rs`

#### 1. Updated `install_highbeam_client_mod()` Function
- Creates temporary ZIP for verification
- **NEW**: Extracts ZIP contents to `mods/highbeam/` directory
- Cleans up temporary ZIP file
- Mod now exists as proper directory structure

#### 2. Added `extract_client_zip_to_mod_dir()` Function
- Opens ZIP archive
- Iterates through all entries
- Creates necessary subdirectories
- Extracts each file to proper location
- Logs completion with directory path

#### 3. Removed Unused Constant
- `HIGHBEAM_CLIENT_ZIP` constant no longer needed (was leaving ZIP in place)

### Result

```
BeamNG.drive/mods/
└── highbeam/                  ✅ Directory structure
    ├── scripts/
    │   ├── modScript.lua      ✅ Root-level bootstrap
    │   └── highbeam/
    │       └── modScript.lua  ✅ Nested bootstrap (supported)
    └── lua/
        └── ge/
            └── extensions/
                ├── highbeam.lua ✅ Main extension
                └── highbeam/     ✅ Subsystem modules
                    ├── connection.lua
                    ├── browser.lua
                    ├── protocol.lua
                    ├── state.lua
                    ├── config.lua
                    ├── chat.lua
                    ├── vehicles.lua
                    └── math.lua
```

---

## Expected Behavior After Fix

### On Launcher Execution

1. **Download phase**: Launcher fetches HighBeam client files
2. **Install phase**: Launcher creates `BeamNG.drive/mods/highbeam/` directory structure
3. **Extract phase**: All files extracted to proper locations
4. **Cleanup phase**: Temporary ZIP deleted

### On BeamNG Start

1. **Mod scan**: BeamNG finds `mods/highbeam/` directory
2. **Script load**: BeamNG executes `highbeam/scripts/modScript.lua`
3. **Extension bootstrap**: modScript calls `extensions.load("highbeam")`
4. **Discovery phase**: GE extension system finds `highbeam/lua/ge/extensions/highbeam.lua` ✅
5. **Initialization**: Extension's `onExtensionLoaded()` hook runs
6. **Menu registration**: Server browser button appears in More menu ✅
7. **Functionality**: Extension ready to accept connections

### User Observable Results

- **Console command**: `extensions.highbeam.openBrowser()` works ✅
- **In-game menu**: "HighBeam Multiplayer" button appears in More menu ✅
- **Server browser**: Window opens, relay list loads, ping tests work ✅
- **Connection**: Server connection established and vehicles sync ✅

---

## Technical Details

### Mod Directory Structure Constraints

BeamNG mod loader requirements:
- Mod must be a **directory** in `BeamNG.drive/mods/`
- Must contain `scripts/modScript.lua` (entry point)
- modScript.lua called in GE Lua context
- Can call `load('name')` or `extensions.load('name')`
- Loaded extensions must be at `lua/ge/extensions/name.lua`

### WHY

BeamNG's extension system works by:
1. Finding mod directories
2. Executing their modScript.lua in the GE Lua runtime
3. modScript calls `load('extensionName')` which searches `lua/ge/extensions/`
4. The extension module is loaded and its hooks registered

ZIP files are **not traversable** by BeamNG's `load()` function, so they must be extracted first.

---

## Verification

### To Verify Fix Works

**In BeamNG console:**
```lua
extensions.highbeam.openBrowser()
```

Expected: Server browser window opens with relay URL, server list, ping tests

**In-game:**
1. Go to main menu
2. Click "More" button (bottom left)
3. Look for "HighBeam Multiplayer" button
4. Click to open server browser

Expected: Browser opens with list of public servers

---

## Deployment

- **Launcher version**: v0.6.8+
- **Client mod version**: v0.6.8+
- **Backwards compatibility**: Existing v0.6.7 mods will be replaced with properly extracted structure
- **Cleanup**: Staged server mods still removed on session end (separate mechanism)

---

## Related Issues Fixed

This fix resolves:
- Extension unavailable error
- Menu button not appearing
- Server browser not opening  
- "attempt to index nil value" error on console

---

## Future Improvements

Could consider:
- Verbose logging during extraction (help debug future issues)
- Checksum verification of extracted files (ensure integrity)
- Atomic extraction (all-or-nothing semantics)
- Support for multiple extension versions (mod versioning)

