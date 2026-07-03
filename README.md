# NoNap

NoNap is a tiny macOS menu bar app for keeping a Mac awake when the lid is closed.

I built it because I wanted Codex, Claude, and other AI agents to keep working while my MacBook was closed. macOS can do this with `pmset`, but I wanted a small switch in the menu bar instead of remembering the command every time.

## What it does

- Keeps the Mac awake with `pmset -a disablesleep 1`
- Restores normal lid sleep with `pmset -a disablesleep 0`
- Offers optional auto-restore timers
- Can launch at login
- Stays out of the way in the menu bar

NoNap asks for an administrator password when it changes the power setting. It does not collect anything, phone home, or store secrets.

## Build

```sh
swift build -c release
```

To build and run the `.app` bundle:

```sh
./script/build_and_run.sh
```

The script writes the app bundle to `outputs/NoNap.app`.

## Requirements

- macOS 12 or newer
- Swift toolchain / Xcode command line tools
- A Mac where `pmset disablesleep` is supported

## Why not just use `caffeinate`?

`caffeinate` is great, but this is specifically for the lid-close sleep behavior. NoNap wraps the `pmset disablesleep` setting in a small menu bar UI so it is easy to see and toggle.

## License

MIT
