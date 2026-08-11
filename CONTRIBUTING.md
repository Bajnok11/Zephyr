# Contributing

Thanks for taking a look. This is a small project with a sharp edge — it writes to your Mac's fan controller — so the bar for changes in the privileged parts is deliberately high.

## Getting set up

```bash
git clone https://github.com/Bajnok11/Zephyr.git && cd Zephyr && swift build
```

`./Scripts/build.sh` assembles and installs the app into `~/Applications`. Use the environment hooks described at the end of [ARCHITECTURE.md](ARCHITECTURE.md) to run against a throwaway config so you don't clobber your own presets while testing.

## What's especially welcome

- **Localisation.** The UI strings are Hungarian and inline in the view files. Moving them to a string catalogue and adding English would be a real improvement.
- **Hardware reports.** If Zephyr misreads your Mac — wrong fan count, sensors named oddly, a model where nothing works — open an issue with the model identifier and, if you can, the output of the sensor browser. Different Macs name their SMC keys differently and the catalogue in `Sensors.swift` only knows what it has seen.
- **Intel Macs.** This was developed against an M1 Pro. Intel Macs use the same keys but not always the same encodings; fixes there are useful.

## Rules for the helper

Changes to `Sources/ZephyrHelper` get read carefully. Please keep to these:

- **Never widen the writable key set.** The helper writes `F<n>Tg` and `F<n>Md` and nothing else. A generic "write any SMC key" command turns a fan utility into a privilege escalation tool.
- **Never remove a safety net.** The connection-close release, the watchdog and the min/max clamp each cover a different failure. Don't trade one away for tidiness.
- **Keep it small.** It runs as root. Every line is a line someone has to audit.
- **Fail closed.** If a request can't be validated, refuse it and release the fans — don't guess.

## Style

Match the surrounding code: descriptive names, no abbreviations, comments only where the *why* isn't obvious from the code. The existing comments explain non-obvious decisions (raw byte offsets in `SMC.swift`, percentages instead of RPM in curves) rather than restating what the line does. Please do the same.

## Pull requests

One concern per PR, with a note on what you tested it against — which Mac, which macOS. If it touches fan control, say explicitly that you watched the fans return to automatic after quitting the app.
