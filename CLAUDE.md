# Shekef (שקף)

Native macOS app for editing and presenting slide decks, Hebrew-first and right-to-left. Swift + SwiftUI shell, with WKWebView drawing the slides. No Electron, no third-party dependencies.

macOS only today. A Windows version is planned, so keep platform-specific code out of `Web/` where possible: that layer is the part most likely to be shared.

## Build and run

```bash
./build.sh            # universal build (arm64 + x86_64) into build/שקף.app
./build.sh install    # also copies to /Applications/שקף.app
swift build -c release 2>&1 | grep error   # fast compile check
```

There is no Xcode project. `build.sh` runs SwiftPM, assembles the `.app` bundle by hand (binary, `Info.plist`, `Web/` into `Resources/web`, `Sounds/` into `Resources/sounds`), and ad-hoc signs it. `Bundle.main` resources only exist inside the bundle, so always run the bundled binary, not `swift run`.

## Headless test modes

The app binary accepts flags that do one job and exit. Use them to check changes without clicking through the UI:

```bash
BIN="build/שקף.app/Contents/MacOS/Shekef"
"$BIN" --import in.pptx out.shekef          # run an importer
"$BIN" --export deck.shekef out.pdf         # pdf, pptx or html by extension
"$BIN" --thumb deck.shekef out.png 3        # render slide 3 to a PNG
"$BIN" --readtest deck.shekef 2             # click the read-aloud button on slide 2 in editor and player; plays sound
```

There is no unit test suite. After changing rendering, import or export, run the relevant mode and look at the output.

## Architecture

Swift owns the data and everything native. The web layer only draws and reports user gestures.

| File | Role |
|---|---|
| `Model.swift` | `Deck`, `Slide`, `Element`, `Loop` (all `Codable`), colour and text helpers, option lists |
| `Store.swift` | `AppState`: the single source of truth. Mutation, undo/redo, autosave, thumbnails, slide and element operations, read-aloud |
| `Web.swift` | `shekef://` URL scheme handler, the editor web view, file drop |
| `Renderer.swift` | Hidden WKWebView that renders slides for thumbnails, PDF pages, rasterised export images and text run extraction |
| `Player.swift` | Full-screen presentation window |
| `Audio.swift` | All sound: effects, attached audio files, `AVSpeechSynthesizer` Hebrew speech |
| `ImportPPTX.swift` | PPTX parser, including transitions and the animation timeline |
| `ImportOther.swift` | ODP, PDF, images, HTML, and Keynote/legacy PPT conversion through AppleScript |
| `Export.swift` | PDF, HTML and PPTX writers |
| `Views.swift`, `App.swift` | SwiftUI interface, menus, command-line modes |

| Web file | Role |
|---|---|
| `stage.js`, `stage.css` | Shared slide renderer. Used by the editor, the player, the renderer and exported HTML |
| `editor.js`, `editor.html` | Selection, drag, resize, rotate, snapping, inline text editing |
| `player.js`, `player.html` | Presentation: transitions, click steps, loops, morph |
| `render.html` | Offscreen rendering and text run extraction for PPTX export |
| `import_html.js` | Runs inside a foreign HTML page and flattens it into slides and elements |

### Data flow

1. Every change goes through `AppState.mutate`. It snapshots the deck for undo, then calls `afterChange`, which pushes the current slide to the editor (`Editor.load`), schedules an autosave and refreshes thumbnails.
2. The editor posts messages back (`select`, `geom`, `text`, `cmd`, `read`) and `AppState.handleEditor` applies them through `mutate`.
3. `Editor.load` diffs by element id and updates nodes in place, so pushing the model back after every change is safe, including during text editing.

### Document format

A deck is a package directory `name.shekef` containing `deck.json` and `media/`. Slides are 1920 pixels wide; `Deck.height` sets the aspect ratio (1080 for 16:9). Media is referenced by file name and served to web views as `shekef://media/<name>`. Bundled web files are served as `shekef://app/<file>`.

Element types: `text`, `image`, `shape`, `embed` (an HTML page in an iframe), `read` (a read-aloud button). A `read` element plays `src` if set, otherwise speaks the text of the element in `target`.

## Conventions

- The interface is Hebrew and right-to-left. User-facing strings are written in Hebrew directly in the code.
- Sound never goes through the web view. The player posts a message and `AudioEngine` plays it. This is what makes read-aloud reliable; do not move it into JavaScript. The JavaScript fallback in `player.js` exists only for exported HTML opened in a browser.
- In the hidden renderer, wait with timers and `img.decode()`, not `requestAnimationFrame` or `img.complete`: neither is reliable in a window that is not on screen.
- Animate elements with the individual CSS properties `translate`, `scale` and `rotate`, not `transform`. Element rotation uses `rotate`, and morph uses `transform`, so they must stay separate.
- New `Element` fields should be optional so older `deck.json` files keep decoding.
- Swift 5 language mode is set in `Package.swift`. UI-facing classes are `@MainActor`.
- The only credit line in the app is "הוכן ע״י שמואל".

## Known gaps

- No video elements.
- PPTX export writes every entrance animation as a fade and drops loops and read-aloud actions.
- PPTX import skips tables and charts.
- ODP, Keynote, legacy PPT and HTML import have had far less testing than PPTX import.
- Unreferenced files in `media/` are never cleaned up.
