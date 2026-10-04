# impro

Scripted, re-recordable screencasts of Emacs packages, for READMEs and
release notes.

You write a short **scenario**: a document, captions, and the keys to press.
impro plays it in a second Emacs, using your own config and theme. Keys go
through the real command loop, so prompts, menus and side windows behave
exactly as when a person types. The mode line shows a caption and the keys
being pressed. impro records only that window and writes `demo.mp4` and
`demo.gif`. Change the package, run it again, and the demo stays up to date.

- **Only the demo window is recorded.** Other windows, notifications and
  anything else on screen never end up in the video, so you can keep
  working while it records.
- **Your Emacs state is never touched.** The demo Emacs keeps its session,
  history, recent files and the like in a temporary folder, and quits
  without running your config's exit hooks.
- **Deterministic.** A scenario replaces network and model calls with
  fixed replies, so every take is the same.

## Requirements

Every platform needs Emacs 29.1 or newer and
[ffmpeg](https://ffmpeg.org).

| Platform                                     | How the window is recorded                                             | Also needs                                                                             |
|----------------------------------------------|------------------------------------------------------------------------|----------------------------------------------------------------------------------------|
| Linux (X11, Wayland, or headless under Xvfb) | The demo Emacs saves its own frames                                    | An Emacs built with Cairo. Most distro GTK builds are, e.g. Debian/Ubuntu `emacs-gtk`. |
| macOS                                        | A small ScreenCaptureKit helper, `wincap.swift`, compiled on first use | Xcode command line tools: `xcode-select --install`                                     |
| Windows                                      | ffmpeg's `gdigrab` window capture                                      | Nothing more. **Untested**, and windows covering the demo may show up.                 |

`M-x impro-doctor` checks all of this and says how to fix what's missing:

```
✓ Emacs 29.1 or newer                                30.1
✓ ffmpeg, to encode the MP4 and GIF                  /usr/bin/ffmpeg
· Recorder                                           frames (auto)
✓ Demo Emacs is built with Cairo (records itself)    yes
✓ A display for the demo window                      :0
```

Optional extras:
- [keycast](https://github.com/tarsius/keycast) shows the keys in the mode
  line; impro has a built-in display otherwise.
- [gptel](https://github.com/karthink/gptel) is used by `impro-draft` to
  write a first scenario from a package's README.

## Install

With Emacs 29+:

```elisp
(package-vc-install "https://github.com/bbw9n/impro")
```

or with `use-package` (Emacs 30+):

```elisp
(use-package impro
  :vc (:url "https://github.com/bbw9n/impro"))
```

Doom, in `packages.el`:

```elisp
(package! impro :recipe (:host github :repo "bbw9n/impro" :files ("*.el" "wincap.swift")))
```

Keep `wincap.swift` next to `impro.el` with any installer: macOS needs it.

## Your first demo, in five minutes

1. Run `M-x impro-doctor` and fix any ✗ line.
2. Run `M-x impro-new` and pick your package's directory. impro writes a
   scenario skeleton, `~/.emacs.d/impro/PKG/PKG-demo.el`, that loads your
   package from its working tree, and opens it.
3. Fill in the document and the steps:

   ```elisp
   (impro-play
    '((caption "my-pkg: rename every match at once" 3)
      (caption "Mark a word — C-c m" 1)
      (goto "tension" 1)
      (keys "C-c m" 2)
      (type "pressure" 0.08)
      (end 1.5)))
   ```

4. Run `M-x impro-lint`. It catches typos, invalid keys and missing text
   instantly, and estimates the length.
5. Run `M-x impro-rehearse`. The demo plays in a new window and the step log
   is shown. A failing step, or a key bound to nothing, stops it with the
   reason.
6. Run `M-x impro-record`, which writes `PKG-demo.mp4` and `PKG-demo.gif`.
   It runs in the background; just don't type into the demo window.

`M-x impro-abort` stops a take.

## Scenarios

A scenario is an Emacs Lisp file that does three things:

- calls `impro-setup`;
- opens a document with `impro-open`;
- plays a list of steps with `impro-play`.

| Step                       | Does                                                               |
|----------------------------|--------------------------------------------------------------------|
| `(caption "TEXT" [SECS])`  | Show TEXT in the document's mode line                              |
| `(goto "TEXT" [SECS])`     | Put point at the first match of TEXT in the document               |
| `(keys "C-c w ;" [SECS])`  | Press a key sequence (`kbd` syntax), through the real command loop |
| `(type "words" [PER-KEY])` | Type characters one by one                                         |
| `(wait SECS)`              | Pause                                                              |
| `(eval FORM [SECS])`       | Run FORM in the document buffer                                    |
| `(end [SECS])`             | Hold the last frame, then quit; always the last step               |

SECS is how long to wait before the next step.

- **`impro-setup`** takes `:columns`/`:lines` or `:maximized t`, plus
  `:font-size` and an optional `:theme`.
- **`impro-open`** takes `NAME TEXT [MODE]`.

Tips:

- **One idea per caption**, and name the keys in it: "Cycle in place — C-c ]".
  Aim for two minutes at most.
- **Give things time to be read.** Menus, panels and replies need 2–4
  seconds. Pause on a highlighted option before `RET`.
- **Keys meant for a prompt** simply follow the keys that opened it: steps run
  on timers, even while the minibuffer is open.
- **Fake every network and model call.** Load the real library, then
  override its request function. A plain `defun` stub gets replaced when the
  package loads the real library, and the demo would then send real requests.

  ```elisp
  (require 'gptel nil t)
  (advice-add 'gptel-request :override
              (lambda (_prompt &rest args)
                (run-at-time 1.0 nil (plist-get args :callback) "A canned reply." nil)))
  ```

- **Keep the package's own state files out of yours.** Point its variables
  into the scenario's folder.

## From a shell, or CI

```sh
emacs --batch -l impro.el -f impro-batch --doctor
emacs --batch -l impro.el -f impro-batch my-demo.el --lint
emacs --batch -l impro.el -f impro-batch my-demo.el --rehearse
emacs --batch -l impro.el -f impro-batch my-demo.el out/my-demo   # writes out/my-demo.mp4 and .gif
```

**Headless Linux** works under Xvfb. Start Xvfb directly: `xvfb-run` can hang
waiting for Xvfb, especially in containers.

```sh
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp & sleep 1
DISPLAY=:99 emacs --batch -l impro.el -f impro-batch my-demo.el out/my-demo
```

This makes re-recording a README GIF in CI on every release a few lines of
config. `make smoke-linux` does exactly this in Docker.

## Settings

| Option                             | Default             |                                                     |
|------------------------------------|---------------------|-----------------------------------------------------|
| `impro-recorder`                   | `auto`              | `frames`, `wincap` or `gdigrab`; see Requirements   |
| `impro-emacs`                      | this Emacs          | The Emacs binary that plays demos                   |
| `impro-clean`                      | `nil`               | Run the demo Emacs with `-Q` instead of your config |
| `impro-directory`                  | `~/.emacs.d/impro/` | Where `impro-new` and `impro-draft` put scenarios   |
| `impro-frame-rate`                 | `12`                | Most frames per second for the `frames` recorder    |
| `impro-gif-width`, `impro-gif-fps` | `960`, `12`         | The GIF; the MP4 keeps full resolution              |
| `impro-max-seconds`                | `300`               | Stop a stuck take                                   |
| `impro-ffmpeg-program`             | `"ffmpeg"`          |                                                     |

## Developing impro

```sh
make check          # compile without warnings, lint the smoke scenario
make doctor
make smoke          # record test/smoke-demo.el here, to out/
make smoke-linux    # the same on Linux, headless, in Docker
```

On macOS, point `make` at the app: `make smoke EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs`.

## Troubleshooting

- **macOS: "Window capture didn't start".** Allow Screen Recording for the
  app running Emacs: System Settings → Privacy & Security → Screen Recording.
- **Linux: "This Emacs can't record itself".** The demo Emacs isn't a Cairo
  build. Install your distro's GTK build, or point `impro-emacs` at one.
- **Doom and keycast:** keycast 1.4.8+ needs newer `cond-let`/`compat` than
  Doom pins. Pin keycast v1.4.7, or let impro's built-in key display take
  over.
- **Something on screen you didn't expect** (a completion popup, a save
  message): your config turns it on during the demo. Turn it off in the
  scenario. impro already turns off company and corfu popups.

## For agents

`SKILL.md` teaches a coding agent (e.g. Claude Code) the whole loop:

- write a scenario from a package's README;
- fake its network calls;
- lint, rehearse and record;
- check frames of the result.
