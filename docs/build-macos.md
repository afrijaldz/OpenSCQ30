# Building on macOS

## Requirements

- Xcode Command Line Tools (`xcode-select --install`) for clang and the IOBluetooth framework
- Rust (see `.build-tool-versions` for the version used in CI)

## Building

```sh
cargo build --release -p openscq30-cli
cargo build --release -p openscq30-gui
```

The binaries will be at `target/release/openscq30` and `target/release/openscq30-gui`.

## App bundle

To get an `OpenSCQ30.app` that can be put in `/Applications` and launched from Spotlight or
Launchpad:

```sh
just build-gui
just build-gui-app
```

This creates `build-output/OpenSCQ30.app` with an ad-hoc code signature. Alternatively, run
`packaging/macos/build.sh` directly after copying `openscq30-gui` to `build-output/`.

## How the macOS backend works

Bluetooth connections go through Apple's IOBluetooth framework, using a small Objective-C shim in
`lib/src/connection_backend/macos/rfcomm.m` that is compiled by `lib/build.rs`.

On current macOS versions, IOBluetooth delivers RFCOMM events (open complete, incoming data,
disconnect) on the main thread's run loop, no matter which thread opened the channel. The GUI
already has a main run loop, but the CLI does not, so on macOS the CLI runs its logic on a
secondary thread while the main thread spins a run loop
(`openscq30_lib::run_with_main_run_loop`). Anything else embedding `openscq30-lib` on macOS
needs to do the same.

The device must already be paired and connected in System Settings > Bluetooth.
