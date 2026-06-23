# FLED
<img width="641" height="304" alt="image" src="https://github.com/user-attachments/assets/e5206e3b-dcfa-4e6b-ab90-948b7d1fca2c" />


Simple DOS editor with Hex and Compare functionality
\# FlabEditor (FLED)

\`FlabEditor\` is a high-performance, retro text editor, interactive hex editor, and visual file comparison utility written in Turbo Pascal for MS-DOS environments. By utilizing low-level x86 assembly language hooks and direct hardware-level video RAM (\`$B800:0000\`) manipulation, it bypasses slow operating system display routines to provide an incredibly snappy, responsive text user interface (TUI).

## Overview

FlabEditor serves as a compact, all-in-one terminal workspace designed for legacy and retro-computing hobbyists, emulation environments, and classic systems. It manages memory buffers safely by suppressing standard compiler runtime range-checking traps (\`{$R-,S-,I-}\`), ensuring robust control even when raw hardware and memory spaces are manipulated directly.

### Key Features

\* \*\*Direct VRAM Rendering:\*\* Bypasses BIOS/DOS standard output calls to write directly to \`$B800:0000\` for instantaneous, tear-free screen refreshes.
\* \*\*Interactive Hex Editor:\*\* Features a live, scrollable dual-column hex-and-ASCII view that syncs modifications directly back into the active text buffer.
* \*\*Visual Diff Tool:\*\* Combines side-by-side binary comparison with color-coded modifications and multiple viewing modes (Combined, Hex Only, and ASCII Only).
\* \*\*Grid File Picker:\*\* Contains an integrated directory browser which dynamically reads file lists and supports native sub-directory navigation.
\* \*\*Low-Level Control:\*\* Custom key listeners use pure BIOS interrupts to monitor state, while cursor manipulation selectively toggles and repositions the hardware cursor.

## How to Use

### Installation \& Compiling

To build and run FlabEditor, you will need a 16-bit Turbo Pascal compiler (such as Turbo Pascal 7.0) and a DOS environment (such as native MS-DOS, DOSBox, or vDos).

1\. Save the source code file as \`FLABEDIT.PAS\`.
2\. Compile the executable using the Turbo Pascal Command Line Compiler (\`TPC\`):

\`\`\`bash
tpc FLABEDIT.PAS
\`\`\`

3\. Run the compiled executable from your DOS command line. You can optionally pass a file path to load it on startup:

\`\`\`bash
FLABEDIT.EXE [FILENAME.TXT]
\`\`\`

### Global Keyboard Shortcuts

The main program interface uses simple functional key binds mapped out on the top menu bar:

\| Key \| Mode / Action \| Description \|
\| :--- \| :--- \| :--- \|
\| \*\*\`F1\`\*\* \| New \| Wipes the active workspace memory and creates a blank document. \|
\| \*\*\`F2\`\*\* \| Open \| Launches the directory navigator grid to load a text file. \|
\| \*\*\`F3\`\*\* \| Save \| Saves the active workspace cleanly to disk (automatically trims trailing spaces). \|
\| \*\*\`F4\`\*\* \| Search \| Scans the workspace. Press \*\*\`N\`\*\* for the next match, or \*\*\`ESC\`\*\* to exit search. \|
\| \*\*\`F5\`\*\* \| Compare \| Loads a second file into a side-by-side Visual Diff engine. \|
\| \*\*\`F6\`\*\* \| Hex Edit \| Enters the live interactive Hex Editor for the current buffer. \|
\| \*\*\`ESC\`\*\* \| Exit / Abort \| Cancels current popup dialogs or safely exits the application to DOS. \|

### Component Navigation

#### Text / Hex Workspace Navigation

\* \*\*\`Arrow Keys\`\*\*: Precision cursor repositioning.
\* \*\*\`Page Up / Page Down\`\*\*: Rapid page-by-page scrolling through the document.
\* \*\*\`Backspace / Enter\`\*\*: Familiar text composition controls.

#### Visual Diff (F5) Mode Controls

\* \*\*\`Arrow Keys\` / \`PgUp\` / \`PgDn\`\*\*: Scrolls both files simultaneously to track disparities.
\* \*\*\`F7\`\*\* \*(scancode mapping)\*: Cycle through the three layout modes (\*Combined\*, \*Hex Only\*, and \*ASCII Only\*).

## Other Important Info

### Constraints and Hardcoded Limits

Because FlabEditor is engineered for raw speed and memory efficiency in 16-bit real-mode, it works with small, high-efficiency arrays:

\* \*\*Max Workspace Rows:\*\* \`100\` lines (\`MAX_LINES\`).
\* \*\*Max Line Width:\*\* \`80\` characters (\`LINE_WIDTH\`).
\* \*\*Viewport Height:\*\* Optimized for a standard 80x25 character display grid.

### Behind the Scenes: The Temporary Sync File

When you launch the Hex Editor (\`F6\`), FlabEditor dynamically drops a hidden swap file named \`FLED$$$.TMP\` on the physical drive. It parses and modifies this binary representation natively, then seamlessly updates the main in-memory text buffer and sweeps up the temporary file upon exit.

\> \*\*Note:\*\* Avoid placing file locks on or manually editing \`FLED$$$.TMP\` during editing sessions.

### Technical Architecture

\* \*\*Direct Color Memory Mapping:\*\* Output writes characters (\`Ch\`) and visual colors (\`Attr\`) simultaneously as byte pairs directly to memory addresses mapped to your system's hardware screen page.
\* \*\*Non-blocking Keyboard Inputs:\*\* Rather than using blocking, high-overhead console functions, FlabEditor taps into raw BIOS Interrupt \`16h\` interfaces to check the keyboard buffer on demand.
