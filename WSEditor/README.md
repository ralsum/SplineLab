# WSEditor

WSEditor is a lightweight WordStar-style text editor.

## Linux command line version

- Full-screen terminal editor with UTF-8 file I/O
- Arrow keys, Home/End, Page Up/Down, Backspace/Delete
- WordStar-style navigation: `Ctrl+E/X/S/D/A/F/R/C/W/Z`
- Edit commands: `Ctrl+G` delete char, `Ctrl+H` backspace, `Ctrl+Y` delete line, `Ctrl+T` delete word right, `Ctrl+B` reflow paragraph
- Prefix commands: `Ctrl+K` file/block actions, `Ctrl+Q` document navigation/delete, `Ctrl+P` bold/underline
- Clipboard paste: `Ctrl+V`
- Direct shortcuts: `Ctrl+O` open
- Save is `Ctrl+K S`

WordStar keys included:
- Second keys may be typed plain or with Ctrl held; `Ctrl+K Ctrl+X` works like `Ctrl+K X`.
- `Ctrl+K S` save file
- `Ctrl+K D` save and exit
- `Ctrl+K X` exit and save
- `Ctrl+K Q` quit without saving
- `Ctrl+K B` begin block
- `Ctrl+K K` end block
- `Ctrl+K C` copy block
- `Ctrl+K V` move block
- `Ctrl+K Y` cut block to clipboard and delete
- `Ctrl+Q Y` delete to end of line
- `Ctrl+Q R` move to beginning of document
- `Ctrl+Q C` move to end of document
- `Ctrl+Q V` move to end of document
- `Ctrl+P B` bold toggle
- `Ctrl+P S` underline toggle

Notes:
- Copied/cut block text is saved to `~/.local/share/wse/clipboard.txt` so it survives editor restarts.
- The last block selection for a file is saved to `~/.local/share/wse/block_state.txt` and restored when you reopen the same file.
- Active blocks are highlighted with reverse video in the editor.

Build on Linux:
```bash
cd WSEditor
./build-linux.sh
```

Run:
```bash
wse
```

Open a file directly:
```bash
wse path/to/file.txt
```

Notes:
- The Linux build installs `wse` into `~/.local/bin`.
- If `~/.local/bin` is not already on your `PATH`, add:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Web version (browser tab)

- Create, open, and save plain text files
- Stores text as UTF-8
- WordStar-style shortcuts (Ctrl+K then N/O/S/A/F/Q)
- Font + size selection (monospace, default Courier New)

Run:
```bash
cd WSEditor/web
node server.js
```

Then open:
```text
http://127.0.0.1:5173/
```

Notes:
- Saving/opening uses the browser File System Access API when available.
- Line endings are normalized to match the native editor behavior.

## Native Windows version (C++)

Build on Windows:
```powershell
./build-windows.ps1
```

Create the desktop shortcut:
```powershell
./create-desktop-shortcut.ps1
```
