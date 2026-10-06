# Mac Cleaner, a Droplet for Droppy

<!-- Written by `droppykit agent`. Add your own notes below; the file is only rewritten with --force. -->

This package is a **Droplet**: an extension that runs inside Droppy, the
Dynamic Island and shelf for Mac, written in SwiftUI against **DroppyKit**.
Droppy loads the built `.droplet` bundle into its own process and draws it on
the notch, the shelf, the lock screen and the menu bar.

- Droplet id: `mac-cleaner`. It is also `MacCleanerDroplet.id` in Swift and `id` in `droplet.json`; the three must agree or the loader refuses the bundle.
- Swift product: `MacCleaner`, a dynamic library. The harness target is `MacCleanerHarness`.
- SDK checkout: `/Users/danny/droppykit` (DroppyKit 1.20.1). Docs online: https://getdroppy.app/docs/droppykit
- Host: Droppy 15.3 or later, which runs an unsigned bundle once its user approves that build under Settings, Store, Local droplets and asks again each time it opens, or the free Droppy Playground (https://getdroppy.app/download/playground), which loads unsigned bundles without asking.

## The loop

Every change goes through all of this, in order. A droplet can compile,
validate and then draw nothing, so a green build is not the end.

1. Edit `Sources/MacCleaner/`. The manifest is `droplet.json`.
2. `droppykit build` writes `.build/MacCleaner.droplet`, universal, linked against the
   framework Droppy ships. Never a bare `swift build` for the bundle: it folds a second
   copy of DroppyKit into the droplet, and that bundle loads in the harness and dies
   inside Droppy at dyld with "Symbol not found".
3. `droppykit validate` runs the exact checks the Store's intake runs.
4. `droppykit run -- --shots ./shots --report ./shots/report.json` renders every surface
   to a PNG without opening a window and writes a JSON verdict. Look at the pictures.
   Read `report.json`: `problems` must be empty and every surface you declared must be
   `provided`.
5. Put the bundle into Droppy Playground and confirm it loaded. Copy
   `.build/MacCleaner.droplet` to
   `~/Library/Application Support/Droppy Playground/Droplets/mac-cleaner/MacCleaner.droplet`,
   relaunch the Playground, and read its Store row: the subtitle is the loader's verdict.

With the DroppyKit MCP server connected, the same steps are the tools `droppykit_build`,
`droppykit_validate`, `droppykit_shots` and `droppykit_install`, and `droppykit_shots`
returns the images inline. This package carries the server in `.mcp.json` (Claude Code)
and `.cursor/mcp.json` (Cursor). Codex: `codex mcp add droppykit -- /Users/danny/droppykit/Scripts/droppykit mcp`.
The other tools are `droppykit_manifest` (a static check, no build), `droppykit_docs`
(the guides and a search over the SDK sources), `droppykit_doctor`, `droppykit_new`,
`droppykit_open_harness` and `droppykit_submit`.

`droppykit run` with no arguments opens the harness window for a person: Droppy's own
Settings panel with a page per surface. You cannot see that window. The shots are your
eyes; take them after every visual change.

`droppykit version` says which SDK checkout the scripts come from and which tag this
package pins; `droppykit update` moves both to the newest release. A build that stops with
"no compiled objects" or "DroppyKit.o not found" is an SDK older than 1.2.1: update it.

## Rules

- **Surfaces and conformances agree.** `surfaces` in `droplet.json` lists what the droplet
  provides; the droplet conforms to the matching protocol for each of them and to nothing it
  does not list. Disagreement is the most common reason a droplet validates and then does
  nothing.
- **Every shelf widget declares both widths.** `preferredSoloWidth` and
  `preferredPairedWidth` are required; Droppy refuses a descriptor that leaves either to a
  host fallback. Solo and paired are different compositions, not one view at two widths:
  branch on `context.isPaired`.
- **Layout traits describe the widget's rectangle.** Every number in
  `ShelfWidgetLayoutTraits` is the area the widget draws in, in points at the Regular shelf
  size, exactly what the harness renders; Droppy adds its own chrome around it. `.fixed(150)`
  is a 150-point rectangle, alone and in a row, clamped to 48 through 480. A widget that needs
  more height declares more; it never pads its way out of a clip. A solo widget is never
  narrower than 352 on a notch or 370 on an island, so lay out to `context.availableSize`.
- **No card, no border around the widget.** Droppy paints nothing behind a widget and almost
  every one of its own widgets lays its content directly on the shelf's black. Put no
  background, fill, outline or rounded box on the widget's root view. `notchSurfaceCardFill`
  is for a tile or a chip inside the widget that has to read as raised, never a frame.
- **Lay the widget out like Droppy's.** The root view fills the rectangle
  (`.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)`) with ONE
  padding, `.padding(context.contentInsets)`, and nothing on top of it. It clears the host's
  rounded clip: 8 on every edge under the 18pt card corner (a notch, and any row on either
  shape), 0 alone on the island, where the island shell clips the card and keeps one even gap.
  The shelf's chrome already inset the rectangle, so never add your own padding or corner
  inset on top: it doubles the gap.
  Leading text, trailing `.monospacedDigit()` numbers, rows that span the
  full width, a header row of a 12pt symbol and a 12pt semibold title with the widget's control
  at its trailing end, `DroppySpacing` steps between rows. Declare the height the content
  needs; never leave unused space or fill it with padding.
- **The physical notch is cleared for you, except on a HUD strip.** The shelf, a takeover,
  a HUD card and a live activity are inset past the camera housing by the host; never pad for
  it. A HUD strip is handed the whole width across the housing: put its content at the two
  outer edges and nothing in the middle (`host.environment.notchGeometry.closedWidth` is the
  housing), the way the World Clock example's strip does. Never centre a strip.
- **Droppy owns every motion around your surfaces; you animate only what you swap.** A live
  activity row and a HUD are mounted exactly like Droppy's own, so never put an entrance
  transition on the view a factory returns (it plays twice). A live activity is compact only:
  hovering or clicking it opens the shelf, `makeExpanded` is not mounted, and Stop / Start
  belong in the shelf widget. A glyph, label or control you swap while a surface is up takes
  `DroppyTransition.compactContent` in a wing or strip and `DroppyTransition.element` in a
  card, never a transition or spring of your own (`minAPI` 1.8.0).
- **Buttons are Liquid Glass, Droppy's own.** `DroppyCircleButtonStyle` (20pt on an item,
  24pt in a row) for an icon action, `DroppyQuietButtonStyle` and `DroppyAccentButtonStyle`
  (`.small`) for labelled ones, `DroppyGlassButtonStyle` for a label with its own sizing.
  Never a flat wash, a bordered chip or a white button of your own. A list with a control per
  row wraps in `droppyFlatGlassControls()`. Only a live activity row's controls keep
  `DroppyLiveActivityControlStyle`.
- **Everything `activate(host:)` starts, `deactivate()` stops.** Timers, observers, tasks,
  connections. Swift cannot unload code, so anything left running runs until Droppy
  relaunches.
- **A widget the user watches holds the shelf open while it runs.** The shelf closes when the
  pointer leaves it; a teleprompter, countdown or live transcript calls
  `host.shelf.setHoldsOpen(true)` when its work starts and `false` the moment it ends
  (`shelf-write`, `minAPI` 1.5.0). A widget with nothing to show until it is configured sends
  the user to its settings pane with `host.workspace.openSettings()`, and asks for permissions
  there through `host.permissions`, never from the shelf.
- **Host calls are gated by `capabilities`.** A service call without its capability in
  `droplet.json` is refused: it returns `false` or `nil` and logs one line. Declare what you
  use and only that; the user sees the list.
- **The principal class does nothing.** `MacCleanerPrincipal` is `@objc`, is named in the
  bundle's `NSPrincipalClass`, and only creates the droplet. It runs before the host is ready.
- **No `main.swift`.** The harness entry is `@main` in
  `Sources/MacCleanerHarness/MacCleanerHarness.swift`, and a file named `main.swift` cannot
  coexist with `@main`.
- **Look like Droppy, not like a guest.** Surfaces are dark. Foreground colours come from
  `AdaptiveColors`, spacing from `DroppySpacing`, radii from `DroppyRadius` with
  `style: .continuous`. No borders or outlines, no gradients, no ALL-CAPS labels, sentence
  case everywhere, and never paint your own background on a widget. Never repeat the page
  header in a settings pane: Droppy already shows the droplet's icon, name, summary and maker
  above it, so the pane starts with its first setting (the Store refuses a pane that shows the
  droplet's own icon or its name as a title). Settings panes are rooted
  in `DropletSettingsPane` (`minAPI` 1.9.0) and built from `DropletSettingsCard`,
  `DropletSettingsSection`, `DropletControlRow`, `DropletToggleRow`, `DropletStackedRow` and
  `DropletSliderRow`; the host mounts the pane in its native grouped form, so the pane's
  content is a list of sections, never a `VStack`, and it places no dividers.
- **`droplet.json` is the truth for the build.** `Info.plist` is generated from it.
  `version` is numeric `major.minor.patch`; `summary` is at most 60 characters;
  `minAppVersion` stays `15.3.0` unless the droplet needs something newer; `kit.minAPI` is
  the oldest DroppyKit API the droplet actually calls. `droppykit build` fails when it is
  older than that and names the calls and the version to set; set that version, never
  lower it to get a droplet loaded.
- **Do not edit anything under `/Users/danny/droppykit`.** That is the SDK checkout; fixes there go
  upstream. This package is where the work is.

## Where the truth is

Read these before guessing at an API. They are on disk, in the SDK checkout.

- Guides, as Markdown: `/Users/danny/droppykit/Sources/DroppyKit/Documentation.docc/`
  `CreateYourFirstDroplet.md`, `DropletSetup.md`, `DesignGuidelines.md`, `ShelfWidgets.md`,
  `LiveActivities.md`, `ExpandedSurfaces.md`, `SettingsPanes.md`, `Icons.md`, `Harness.md`,
  `HostSupport.md`, `Playground.md`, `Submitting.md`, and `BuildWithCodingAgents.md` for this
  workflow in full.
- The surface protocols, one file each: `/Users/danny/droppykit/Sources/DroppyKit/Capabilities/`
- The host services a droplet calls: `/Users/danny/droppykit/Sources/DroppyKit/Services/DropletServices.swift`
  and `/Users/danny/droppykit/Sources/DroppyKit/Core/DropletHost.swift`
- The manifest type, with every field documented: `/Users/danny/droppykit/Sources/DroppyKit/Bundle/DropletManifest.swift`
- Design tokens and the settings components: `/Users/danny/droppykit/Sources/DroppyKit/DesignSystem/`
- A complete droplet that uses every surface: `/Users/danny/droppykit/Examples/WorldClock/`
- The compatibility promise and the version ledger: `/Users/danny/droppykit/COMPATIBILITY.md`

## Surfaces

| `surfaces` value in droplet.json | Conform to | Shot |
| --- | --- | --- |
| `shelf-widget` | `ShelfWidgetProviding` | `shelf-widget.png` |
| `live-activity` | `LiveActivityProviding` | `live-activity.png` |
| `expanded-surface` | `ExpandedSurfaceProviding` | `expanded-surface.png` |
| `settings-pane` | `SettingsPaneProviding` | `settings-pane.png` |
| `hud` | `HUDPresenting` | `hud.png` |
| `lock-screen-status` | `LockScreenStatusProviding` | `lock-screen.png` |
| `menu-bar-extra` | `MenuBarExtraProviding` | `menu-bar.png` |

`overview.png` shows the identity card with a verdict pill per surface, `capabilities.png`
the capability switches, `preferences.png` every stored value, and `activity.png` every host
call in order, refused ones marked.

## Done means

- `droppykit build` and `droppykit validate` both pass.
- The report's `problems` is empty and `activation.error` is null.
- You have looked at the shot of every surface you touched.
- The bundle loaded in Droppy Playground: `droppykit_install` says loaded, or the Store row
  shows it switched on.
- `droplet.json` still describes what the code does: surfaces, capabilities, summary.

## Package layout

```
Package.swift                     product MacCleaner (dynamic) and MacCleanerHarness
droplet.json                      the manifest; Info.plist is generated from it
Sources/MacCleaner/              the droplet
Sources/MacCleanerHarness/       the @main harness entry; never main.swift
MacCleaner.icon/                 Icon Composer document, required
Assets/Creator.png                square creator avatar, at least 256px, required
.build/MacCleaner.droplet        what droppykit build writes
AGENTS.md, CLAUDE.md, .cursor/    this brief and the agent wiring
.mcp.json, .cursor/mcp.json       the DroppyKit MCP server; absolute paths for this Mac
```

## Submitting

Your own build runs in Droppy only after you approve it under Settings, Store, Local
droplets, and Droppy asks again each time it opens; everyone else gets the droplet from
the Store, signed by Droppy after review.
When the droplet is done: replace the placeholder icon and creator avatar, fill in
`creator` and `source` in `droplet.json`, write `CHANGELOG.md`, and run `droppykit submit`.
The Store is a repository (gitlab.com/droppyformac1/droplets, one folder per droplet):
`submit` forks it, copies this package into `droplets/<id>/`, pushes a branch and opens
the merge request; when a maintainer merges it, the pipeline builds, signs and publishes
it. `droppykit submit --print` shows the plan without doing it (needs `glab`, signed in).
Opening the merge request means accepting the Droplet developer terms at
https://getdroppy.app/droplet-developer-terms.
