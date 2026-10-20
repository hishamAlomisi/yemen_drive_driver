# Driver splash

The supplied captain logo and the app icon are the bitmap assets in the composition.
The scenery, Arabic text, benefit icons, loading indicator and light trace are
Flutter widgets and painters.

## Entrance and cost

- A finite 1,600 ms controller fades/slides the brand, gently scales the logo from
  94%, then reveals the tagline and benefits from right to left.
- A separate 2,400 ms controller repeats the gold trace along the logo silhouette
  and each benefit border while checking the network/API and initializing services.
  Only the narrow trace layers repeat; the entrance does not restart.
  `tool/branding/generate_splash_outline.py` derives the 269-point logo path
  offline; the application does not process image pixels.
- Path metrics are cached per size. The trace uses thin layered strokes without
  animated blur or shader effects. Repaint boundaries isolate the static scenery
  and logo. Animation frames do not rebuild the whole splash.
- Success/failure stops the light-sweep controller and removes its outline.
  Failure immediately completes the entrance and removes the loading ticker.
  Retrying resumes the connection indicator and trace without replaying the entrance.
- Reduced-motion settings show the complete composition immediately. Controllers
  are disposed with the screen. There is no delay to wait for the animation when
  the API and application services are ready.
- The bootstrap splash starts the entrance. The subsequent route uses a completed
  composition so the entrance does not restart during service initialization.

These constraints bound the extra rendering work; device frame times have not
been benchmarked across phones.

## Connection

Startup checks the active network interface, then sends a public catalog read to
the configured API (`ServiceKindModel`, `list`). The interface check is bounded
at 3 seconds and the API request at 8 seconds. Offline, timeout, unavailable
server and initialization failures show a readable message and retry button.
Successful initialization retains login, remembered-session and notification
navigation. Parallel retry calls share one request.

## Validation and preview

`flutter test --no-pub` exercises splash navigation, retry, finite animation,
reduced motion and small/landscape layouts, alongside existing driver tests.

Generate preview frames only for the splash tests:

```powershell
flutter test --no-pub test/splash_flow_test.dart --dart-define=UPDATE_PREVIEWS=true --update-goldens
```

`docs/previews/splash-entrance.gif` is a repeating preview. The app's entrance
plays once while the light trace repeats until the connection check completes.
The frame source is under `../work/splash-motion-loop-frames`.

Build a native MEmu APK with an explicit ABI split:

```powershell
flutter build apk --release --target-platform android-x64 --split-per-abi --no-pub
```

Use `build/app/outputs/apk/release/app-x86_64-release.apk` (Flutter normally also
copies it to `build/app/outputs/flutter-apk`). A single-platform
build without `--split-per-abi` can still include ARM copies of plugin libraries,
causing MEmu to select ARM even though Flutter's application library is x86_64.

The x86_64 release was installed on MEmu and its startup failure message/retry
button were verified with the local API unavailable. Tests cover repeated gold
tracing during connection, a single entrance, and no idle tickers after success,
failure or reduced-motion selection.
