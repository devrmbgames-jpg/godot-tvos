# Godot 3.6.3 for tvOS

This port imports the supplied tvOS implementation onto the exact
`3.6.3-stable` release (`a3378686f7196db78d7b3cc7947f72a13bc4864c`).
The development branch is `feature/godot_3_tvos`.

## Requirements and build

- macOS with Xcode and the Apple TV device/simulator SDKs.
- Python 3 and SCons 4.7 (`python3 -m pip install scons==4.7.0`).
- Minimum deployment target: **tvOS 15.0**, for both device and simulator.
- Device architecture: `arm64`. Simulator architectures: `arm64`, `x86_64`.

Build from the repository root:

```sh
# Apple TV debug and release export libraries.
scons platform=tvos tools=no target=release_debug arch=arm64 -j8
scons platform=tvos tools=no target=release arch=arm64 -j8

# Debug and release libraries for Apple Silicon and Intel simulators.
scons platform=tvos tools=no target=release_debug arch=arm64 simulator=yes -j8
scons platform=tvos tools=no target=release_debug arch=x86_64 simulator=yes -j8
scons platform=tvos tools=no target=release arch=arm64 simulator=yes -j8
scons platform=tvos tools=no target=release arch=x86_64 simulator=yes -j8

# Package the libraries and Xcode project into bin/tvos.zip.
python3 platform/tvos/build_template.py \
  --debug bin/libgodot.tvos.opt.debug.arm64.a \
  --release bin/libgodot.tvos.opt.arm64.a \
  --debug-simulator bin/libgodot.tvos.opt.debug.arm64.simulator.a bin/libgodot.tvos.opt.debug.x86_64.simulator.a \
  --release-simulator bin/libgodot.tvos.opt.arm64.simulator.a bin/libgodot.tvos.opt.x86_64.simulator.a \
  --frameworks-output bin/xcframeworks \
  --output bin/tvos.zip
```

Set `TVOSPATH="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"` on the
SCons command if Xcode is installed outside `/Applications/Xcode.app`.
`TVOSSDK` may be supplied explicitly; otherwise SCons queries `xcrun` for the
selected device or simulator SDK. Bitcode is not enabled.

`--debug-simulator` and `--release-simulator` accept one or more matching
simulator libraries. The packager merges simulator architectures with `lipo`
and puts device and simulator libraries into **separate XCFramework slices**.
An arm64 device archive must never be merged with an arm64 simulator archive.
At least one of `--debug` or `--release` is required. The command above produces
`libgodot.tvos.debug.xcframework` and `libgodot.tvos.release.xcframework` in
`bin/xcframeworks`, each supporting device arm64 and simulator arm64/x86_64.
Both bundles are also included in `tvos.zip` with the Xcode project template.
The packager checks the generated platform/architecture manifest against its
input libraries before publishing the outputs.

Use `--smoke-projects bin/tvos-smoke` to render separate `debug` and `release`
Xcode link-test projects from the matching bundles. These projects contain an
empty PCK and are intended for build verification, not gameplay. The older
`--smoke-project PATH` option still renders one project, preferring Debug.

Build the desktop editor from this same branch, for example on a Mac:

```sh
scons platform=osx tools=yes target=release_debug arch=arm64 -j8
```

In the custom editor, add a **tvOS** export preset, set the team ID and bundle
identifier, and select `bin/tvos.zip` as the custom template for each available
configuration. Export to a directory **outside the Godot project**, then open
the generated `.xcodeproj`. The export produces the Xcode project, PCK and
engine library; Xcode performs application building and signing. Configure
the application's own icon assets, signing and entitlements in its Xcode
project or in a custom template.

Existing device-only custom templates containing
`libgodot.tvos.debug.fat.a` / `libgodot.tvos.release.fat.a` remain supported.
Their scene manifest and directional-remote declaration are added during
export when missing. Native plugins stay in `res://tvos/plugins/*.gdatvp`.
Editor export plugins use the separate `add_tvos_*` API, keeping their tvOS
libraries distinct from iOS libraries.

## UIScene lifecycle

`GodotApplicalitionDelegate` keeps its original class name for compatibility
with existing native integrations. It creates `SceneDelegate` configurations.
`AppDelegate` is shared by the application and scene service registries.

- The process initializes the engine once. `scene:willConnectToSession:options:`
  creates its `UIWindow` with `initWithWindowScene:`.
- The application supports one game window. Scene reconnects reuse the engine,
  view controller, renderer and GL context.
- Resigning active cancels pending input, releases controller state, and stops
  rendering, audio and native video playback.
- Background and foreground callbacks send Godot `NOTIFICATION_APP_PAUSED`
  and `NOTIFICATION_APP_RESUMED`. Rendering resumes after the scene becomes
  active, without the previous delayed-focus callback.
- Audio interruptions respect the scene state. Ending an interruption in the
  background does not restart rendering or audio.
- Scene services receive scene callbacks. Existing application-delegate-only
  plugins receive compatible lifecycle and URL/user-activity callbacks. Cold
  launch URLs and early warm URL/user-activity events are held until
  `Main::start()` and the main loop's initial scene setup have completed.
  This does not wait for a game's own asynchronous initialization.
- Native video keeps explicit user pause separate from lifecycle pause and
  cleans up observations when stopping or replacing an item.

The new manifest is in
[`misc/dist/tvos_xcode/godot_tvos/Info.plist`](../../misc/dist/tvos_xcode/godot_tvos/Info.plist).
For an existing hand-maintained Xcode project, copy its
`UIApplicationSceneManifest`, `GCSupportedGameControllers` and
`GCSupportsMultipleMicroGamepads` entries, replace the engine library, set the
deployment target to 15.0, and retain the `-ObjC` linker flag. Include
`Security.framework` alongside the engine's other frameworks. The source of
truth for linker settings is the supplied Xcode project template.

The port preserves the original tvOS `user://` location in the caches
directory. tvOS can reclaim cached data; game save persistence should follow
the application's existing storage/sync design.

## Controller input

`ViewController` derives from `GCEventViewController`. Gameplay uses Game
Controller profiles; the system keyboard and presented native controllers
temporarily use UIKit. Controller callbacks run on the main queue.

### Siri Remote

| Control | Godot event |
| --- | --- |
| Center click | Button 0 (`JOY_SONY_X`, A / accept) |
| Outer ring | Buttons 12–15 (`JOY_DPAD_UP/DOWN/LEFT/RIGHT`) |
| Touch surface movement | Axes 0/1 (left stick convention; Y inverted) |
| Play/Pause | Button 2 (`JOY_SONY_SQUARE`) |
| Menu/Back, while overridden | Button 1 (`JOY_SONY_CIRCLE`) |
| Touch contact, when supplied by the profile | Button 5 (retained port convention) |

New Siri Remotes use `GCInputDirectionalCenterButton` and
`GCInputDirectionalCardinalDpad` independently. A click on the ring cannot
also emit button A through the whole-clickpad `micro.buttonA` element.
Older micro profiles retain their immediate button-A handling.

`Engine.get_singleton("tvOS").set_overrides_menu_button(true)` lets the game
handle Menu/Back; `false` restores the system action. The original default
(`true`) is retained. This setting does not disable Home/TV system gestures.
On native UI, the system Menu policy is restored temporarily.

Touch contact prefers `GCControllerTouchpad`, then a capacitive button touch
callback. UIKit indirect-touch observation is a fallback whose delivery is
device/profile dependent. A nonzero axis is never treated as proof of
finger contact. UIKit fallback presses with an ambiguous controller identity
are not assigned to a random player.

### Extended gamepads

| Control | Button / axis |
| --- | --- |
| A, B, X, Y | Buttons 0, 1, 2, 3 |
| Left / right shoulder | Buttons 4 / 5 |
| Left / right trigger | Buttons 6 / 7 and axes 6 / 7 |
| Left / right stick click | Buttons 8 / 9 |
| Options / Select | Button 10 |
| Menu / Start | Button 11 |
| DPad | Buttons 12–15; additional axes 4/5 |
| Home / Guide, if delivered by the system | Button 16 |
| Left / right stick | Axes 0/1 and 2/3 |

The DPad never overwrites a held stick. Connections queued during startup are
deduplicated; disconnect also removes pending connections. Disconnect, focus
loss and native-UI handoff release buttons, reset axes and clear touch state.

## Validation

Configuration tests use the real SCons environment without an Apple SDK:

```sh
python3 -m unittest discover -v -s platform/tvos/tests -p test_build_configuration.py
```

Export integration tests require an editor built from this branch. They
execute the C++ exporter and validate scenes, profiles, debug/release library
selection, legacy templates, native-plugin paths, XML escaping and rejection
of an export that would overwrite project sources:

```sh
GODOT_BIN=/absolute/path/to/custom/editor \
  python3 -m unittest discover -v -s platform/tvos/tests -p test_export_project.py
```

The fixture archives used by these export tests contain placeholder libraries;
they test packaging and are not runnable applications.

The **tvOS Builds** GitHub Actions workflow automatically builds complete Debug
and Release XCFrameworks on relevant pushes to `feature/godot_3_tvos`. Each
configuration contains an Apple TV arm64 library and a universal simulator
library with arm64 and x86_64 architectures. All six libraries use the
repository's shared `godot-build` action, an Intel `macos-26-intel` runner and
Xcode 26.3, with a separate SCons cache for each target/platform/architecture.
Building these static libraries and link-test apps does not require signing
certificates, an Apple developer team or a game project.

Open **Actions → tvOS Builds → the completed run → Artifacts** to download:

| Artifact | Contents |
| --- | --- |
| `godot-tvos-xcframeworks` | `libgodot.tvos.debug.xcframework`, `libgodot.tvos.release.xcframework`, and `SHA256SUMS` |
| `tvos-export-template` | `tvos.zip` with both XCFrameworks and the Xcode project template, plus its SHA-256 checksum |
| `godot-tvos-release_debug-arm64` | Device `libgodot.tvos.opt.debug.arm64.a` and checksum |
| `godot-tvos-release-arm64` | Device `libgodot.tvos.opt.arm64.a` and checksum |
| `godot-tvos-simulator-<target>-<arch>` | Individual simulator static library and checksum |

The packaging job verifies all downloaded library checksums, creates separate
device/simulator XCFramework slices, and links unsigned Xcode applications for
**Debug and Release × device arm64, simulator arm64, simulator x86_64**. It only
publishes the XCFrameworks and `tvos.zip` after all six links succeed. Each
individual `.a` uploads independently, so a failed variant does not hide other
successful libraries. Artifacts are retained for 30 days; the completed job
summary contains download links. Use GitHub's **Re-run jobs** to repeat a run.

The `workflow_dispatch` input `build_simulators` defaults to `true`. Setting it
to `false` requests only the two device `.a` files; push builds always include
the full XCFrameworks. GitHub displays the manual **Run workflow** button once
the workflow is present on the repository's default branch.
Enable Actions for the fork if GitHub has disabled its inherited workflows.

For a custom Godot editor built from this branch, select `tvos.zip` as the
custom tvOS export template. For an existing Xcode application, unpack the
XCFramework artifact and link the bundle matching the exported configuration
(Debug or Release). Add it under **Frameworks, Libraries, and Embedded Content**
as **Do Not Embed**, since it contains static libraries. Preserve the scene
manifest and linker settings described above; the XCFramework packages the
engine library but does not replace the application's Info.plist or native
integration code. To verify the unpacked bundle files, run
`shasum -a 256 -c SHA256SUMS` from the artifact's root directory.

Before shipping an application, check these behaviors on actual hardware:

| Area | Device check |
| --- | --- |
| Launch / scenes | Cold launch; fast Home → app return; repeated background/foreground; reconnect without second engine initialization |
| Input reset | Hold each direction/button while backgrounding or disconnecting; no held input after return |
| Siri Remote | Fast center clicks; all ring directions; Play/Pause; Menu override on/off; old and new remote generations |
| Extended controller | Both sticks; simultaneous stick + DPad; trigger values; L3/R3; Options/Start; reconnect |
| Native UI | Keyboard text entry and cancellation; modal alert dismissal; return to gameplay input |
| Video / audio | Background while playing and while explicitly paused; interruption end in background; repeated video start/stop |
| Plugins | Cold and warm URL launch; scene-aware and legacy delegate registration |
| Rendering | GLES2 and GLES3 launch; resize/reconnect; no GL presentation while backgrounded |

## References

- [Godot 3.6.3 iOS platform](https://github.com/godotengine/godot/tree/3.6.3-stable/platform/iphone)
- [Apple: transitioning to the UIKit scene lifecycle](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle)
- [Apple: supporting the second-generation Siri Remote](https://developer.apple.com/documentation/gamecontroller/letting-players-use-their-second-generation-siri-remote-as-a-game-controller)
- [Apple: GCEventViewController](https://developer.apple.com/documentation/gamecontroller/gceventviewcontroller)
- [Apple: supported game-controller profiles](https://developer.apple.com/documentation/bundleresources/information-property-list/gcsupportedgamecontrollers)
