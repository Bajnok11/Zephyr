# Architecture

Zephyr is a Swift package with three targets. The split is drawn along the privilege boundary: everything that needs root lives in one small, auditable binary, and everything else runs as you.

```
┌─────────────────────────────────────────────┐
│ Zephyr.app (your uid)                       │
│                                             │
│  StatusItemController ── menu bar, popover  │
│  AppState ───────────── 1 Hz control loop   │
│  SwiftUI views ──────── panel, settings     │
│         │                                   │
│         │ HelperClient (unix socket)        │
└─────────┼───────────────────────────────────┘
          │ /var/run/zephyr-helper.sock (0600)
┌─────────┼───────────────────────────────────┐
│ zephyr-helper (root, LaunchDaemon)          │
│                                             │
│  line protocol → clamp → SMC write          │
└─────────────────────────────────────────────┘
                    │
              AppleSMC (IOKit)
```

## Targets

### `ZephyrKit`

Shared library, no UI.

| File | Responsibility |
|---|---|
| `SMC.swift` | The IOKit conversation. Builds the 80-byte parameter struct **by raw byte offsets** rather than mirroring the C layout in Swift — Swift makes no guarantees about struct padding, and one misplaced byte here means garbage temperatures. Handles `flt `, `ui8/16/32`, `si8/16`, `sp78`, `sp87`, `fpe2`, `fp88` and `flag` encodings. |
| `Sensors.swift` | Maps raw SMC keys to human names and groups, and defines `CurveSource` (hottest / group / specific key). |
| `Hardware.swift` | `HardwareMonitor`: discovers fans and sensors once at startup, then polls them cheaply. Discovery probes every `T*` key and drops the ones that read implausibly, because the SMC advertises sensors that aren't populated on a given model. |
| `Presets.swift` | `FanCurve`, `Preset`, `Settings`, JSON persistence. |
| `HelperProtocol.swift` | Shared constants plus `HelperClient`, the socket client. |

### `ZephyrHelper`

A single `main.swift`. Runs as root from a LaunchDaemon, opens the SMC, listens on a unix socket, and accepts five commands. It:

- verifies the peer's uid with `LOCAL_PEERCRED` before accepting anything, on top of the socket being `0600` and owned by the installing user;
- clamps every requested RPM into `[F<n>Mn, F<n>Mx]` as read from the hardware;
- writes only `F<n>Tg` and `F<n>Md` — no other key is reachable through the protocol;
- serves each connection on its own thread, with a new connection taking control from the previous one, so a wedged client can never lock out a healthy one;
- releases the fans on connection close, on watchdog timeout, and on `SIGTERM`/`SIGINT`/`SIGHUP`;
- ignores `SIGPIPE`, so a client that vanishes mid-write cannot take the daemon down.

### `Zephyr`

The app.

| File | Responsibility |
|---|---|
| `main.swift` | `NSApplication` bootstrap, accessory activation policy. |
| `AppState.swift` | The control loop. Polls hardware off the main thread once a second, resolves which preset is actually in force, computes the target percentage, ramps toward it, and pushes it to the helper. Also owns helper installation and the login item. |
| `StatusItemController.swift` | The status item, the rotation animation, the popover, the right-click menu and the settings window. |
| `FanIcon.swift` | Draws the fan glyph at an arbitrary angle, as a template image for the menu bar and in colour for the app icon. |
| `Views/` | SwiftUI: `ControlPanelView` (the popover), `SettingsView`, `CurveEditorView`, shared components. |

## The control loop

Every second, `AppState.tick()`:

1. reads a `HardwareSnapshot` on a utility queue;
2. resolves the **effective preset** — power-source automation can override the user's pick;
3. asks it for a target percentage, with emergency cooling overriding everything above the threshold (and 4 °C of hysteresis before it lets go);
4. converts the percentage to RPM per fan using that fan's own min/max;
5. limits the change to `rampStep` RPM per tick;
6. sends `SET` for each fan — which doubles as the watchdog heartbeat.

If the preset is *Automatic*, the loop sends `AUTOALL`, disconnects, and the helper's connection-close path releases the fans. The disconnect is deliberate: not holding a socket open while idle means there is nothing to leak.

## Why a percentage, not an RPM

Curves store fan speed as 0–100 % of each fan's *usable* range rather than absolute RPM. The two fans in a MacBook Pro have different maxima (5779 and 6241 on the M1 Pro this was built against), and a curve written on one Mac would be nonsense on another. Percentages travel.

## Testing hooks

Two environment variables exist for development and screenshots:

- `ZEPHYR_SETTINGS=/path/to/settings.json` — run against a throwaway configuration instead of the real one.
- `ZEPHYR_SHOW_PANEL=1|window|settings|all` — open the panel and/or settings at launch, without hunting for the status item.
