# Contributing to Notchbench

Thanks for your interest! Bug reports, ideas and pull requests are all welcome.

## Reporting bugs and requesting features

Open an [issue](https://github.com/edincokic/notchbench/issues) and pick the bug report or feature request form.
For bugs, include your macOS version, your Mac model and the steps to reproduce.

## Building from source

Requirements: macOS 14 or later and Xcode 16 or later.

```bash
git clone https://github.com/edincokic/notchbench.git
cd notchbench
./install-local.sh
```

`install-local.sh` builds a Release copy and installs it to `/Applications/Notchbench.app`.
To work on the code, open `boringNotch.xcodeproj` in Xcode and run the `boringNotch` scheme.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Keep each pull request focused on one change.
3. Make sure the project builds and describe how you tested it.
4. New tabs live in `boringNotch/components/<Feature>/`. Anything that needs access outside the
   app sandbox (other processes, files, `launchctl`) goes through the XPC helper in
   `BoringNotchXPCHelper/`.

## License

By contributing, you agree that your contributions are licensed under the
[GNU General Public License v3.0](LICENSE), the same license as the rest of the project.
