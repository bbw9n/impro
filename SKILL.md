---
name: impro
description: Record a scripted screencast (MP4 + GIF) of an Emacs package for a README or release — in the user's own Emacs (e.g. Doom), caption and keys (keycast) in the mode line, real keypresses through the command loop, deterministic and re-recordable. Records only the Emacs window and never writes the user's Emacs state. Use when asked to make, update, or re-record a demo, screen recording, GIF, or video of an Emacs package. Linux (Cairo Emacs; also headless under Xvfb), macOS (ScreenCaptureKit) and, untested, Windows; needs ffmpeg.
---

# impro

Plays a **scenario** in the user's own Emacs and records it. Keys go
through the real command loop on a timer, so prompts, previews, timers and
side windows behave exactly as when a person types. The document's mode
line shows a caption, then the keys pressed and their commands (keycast if
it loads, otherwise a built-in segment styled the same). Nothing is added
to other windows' mode lines or above the text.

## Files

- `impro.el`: the whole package. The player (`impro-setup`, `impro-open`, `impro-play`; step syntax in its Commentary) the recorder (`impro-record`, `impro-rehearse`, `impro-abort` in the user's Emacs; `impro-batch` from a shell), `impro-lint`, and `impro-draft` (README → scenario through gptel, for users without an agent; its rules, `impro--draft-rules`, match this workflow).
- `README.md`: install, requirements per platform, the step reference.
- Recorders (`impro-recorder`, picked by system): `frames` on Linux, where the demo Emacs saves its own frames (needs a Cairo build); `wincap` on macOS; `gdigrab` on Windows (untested). Run `emacs --batch -l impro.el -f impro-batch --doctor` first: it checks ffmpeg, the recorder and the display, and says how to fix what's missing.
- `wincap.swift` (macOS): records **one window** (by owning process) with ScreenCaptureKit. Compiled to `~/.config/emacs/impro/wincap` (`impro-wincap-program`) on the first recording, and again when the source changes (needs `swiftc`).
- `.local/` (git-ignored): **scenarios are one-off scripts, not project files.** Generate each one at `.local/<package>/<package>-demo.el`, and write its outputs and state beside it. Never add scenarios to the demoed package's repo; copy only the finished GIF/MP4 there if the user wants it in a README.

## Workflow

1. **Generate the scenario** at `.local/<package>/<package>-demo.el`; `impro-new`'s template is a good start (`emacs --batch -l impro.el --eval '(let ((impro-directory ".local/")) (impro-new "PKG-DIR"))'`) (see `.local/write-on/write-on-demo.el` if it exists). Fill the window with a real-length document, one idea per caption, ~2 minutes at most. Use original sample text, not someone else's writing.
   - Load the package from its working tree (`(load "~/path/to/pkg/pkg.el" nil t)`), even if the user's config already loads a copy.
   - Point the package's own state files into `.local/<package>/`.
   - Give each menu, panel and pane enough `SECS` to be read, and pause on the highlighted option before `RET`.
2. **Make it deterministic.** Replace network and model calls with fixed replies on a fixed delay. Load the real library first, then `advice-add … :override`: a plain `defun` stub is silently replaced when the package loads the real library, and the demo would then send real requests with the user's credentials. Tell the user that the AI output in the demo is pre-recorded.
3. **Lint** (instant, nothing runs): `emacs --batch -l impro.el -f impro-batch SCENARIO.el --lint`. Fix every `error`; check each `warning`. It also estimates the length. Rehearse and record lint first and refuse a scenario with errors.
4. **Rehearse** (no recording): `emacs --batch -l impro.el -f impro-batch SCENARIO.el --rehearse`. A window opens and plays, then the step log is printed. A failing step, a key that isn't bound to anything (it would type stray characters), or a scenario that fails to load, quits with the error (and the document's text at that moment).
5. **Ask before recording.** Then, from this folder:
   ```bash
   emacs --batch -l impro.el -f impro-batch .local/write-on/write-on-demo.el .local/write-on/write-on
   ```
   Only the demo window is recorded, so the user can keep working, as long as they don't type into the demo window.
6. **Check the result before reporting it.** Pull frames from across the video and look at them:
   ```bash
   ffmpeg -v error -i OUT.mp4 -vf "fps=1/10,scale=640:-1,tile=4x4" -frames:v 1 /tmp/sheet.png
   ```
   Check that captions are readable, the keys show up, each scene does what its caption says, and nothing is cut off. Zoom into the echo area too: stray messages (completion lookups, saves) are easy to miss on a contact sheet. Fix timing (`SECS` on steps) or steps and record again.

## Defaults and knobs

- **Emacs:** the demo runs the same binary as the Emacs running impro (`impro-emacs` overrides it), with the user's config; `impro-clean` uses `emacs -Q`. From a shell, set options before `-f`: `--eval '(setq impro-clean t)'`.
- **Look:** `(impro-setup :maximized t :font-size 16)` (or `:columns`/`:lines`). The user's theme stays unless `:theme` is given.
- **Limits:** `impro-max-seconds` (default 300) stops a stuck run. `impro-gif-width` (default 960) and `impro-gif-fps` (default 12) shape the GIF.

## Safety: what the demo must never touch

- **The user's screen:** `frames` and `wincap` capture only the demo window's own pixels, even if other windows cover it or it's on another Space. Never go back to region or full-screen capture (ffmpeg avfoundation, x11grab of the screen): anything the user does on screen ends up in the video. `gdigrab` (Windows) can show windows covering the demo: tell the user.
- **The user's Emacs state:** the demo Emacs runs the user's config, which saves sessions, recent files, history and places. `impro--isolate` points those files (persp workspaces, recentf, savehist, saveplace, bookmarks, transient, org-persist, undo-fu-session, projectile, tramp, shell-maker) into the work directory, turns off workspace autosave, and the demo quits through `impro--quit`, which skips `kill-emacs-hook`. The recorder only ever force-kills Emacs (`SIGKILL`): a normal kill runs that hook. When adding support for another config, check what it writes on exit and redirect that too.
- To verify, list `~/.config/emacs/.local/{etc,cache}` (or `~/.emacs.d`) file mtimes before and after a run; nothing should change.

## Gotchas

- **Steps run on timers**, including while a minibuffer is open, so keys meant for a prompt simply follow the key that opened it. Give a slow step (a model reply, a pane opening) enough `SECS` before the next keys.
- **Batch mode can't run this:** idle timers and completion UIs need a real frame. Don't play scenarios inside `emacs --batch` (`impro-batch` only drives a separate, real demo Emacs).
- **Fullscreen configs:** the runner lets the config go fullscreen, then leaves it with `toggle-frame-fullscreen` (which also brings the window's Space into view) and maximizes or sizes the frame.
- **Completion popups:** configs often turn completion on globally later (Doom: on the first keypress, with `company-ispell` running `look`). The runner sets `company-global-modes` and `global-corfu-modes` to nil and clears completion sources in the demo buffer.
- **keycast placement:** the runner doesn't use `keycast-mode-line-mode` (it inserts at a fixed spot doom-modeline lacks, and its default window predicate follows the bottom-right window, i.e. Helm's or a side panel's). It hooks `keycast--update`, puts `keycast-mode-line` in `global-mode-string`, and limits it to the demo document's window. keycast 1.4.8+ needs newer `cond-let`/`compat` than Doom pins; Doom users should pin v1.4.7 (`b831e380c4deb1d51ce5db0a965b96427aec52e4`). A keycast that fails to load falls back to the built-in display.
- **Headless Linux:** start Xvfb directly (`Xvfb :99 -screen 0 1280x800x24 & DISPLAY=:99 emacs --batch ...`); `xvfb-run` can hang waiting for Xvfb, especially in containers.
- **Screen Recording permission (macOS):** if `wincap` can't start, the app running impro (the user's Emacs, or the terminal running `impro-batch`) needs System Settings → Privacy & Security → Screen Recording. Only the user can grant this.
- **Window choice:** wincap records the process's largest *titled* window. Leaving fullscreen can leave an untitled, screen-sized window behind that never updates; picking it gave 2-frame videos.
- **A failed take produces no output.**
