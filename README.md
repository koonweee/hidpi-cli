# hidpi-cli

A macOS terminal menu for HiDPI resolutions. Pick a size, try it with automatic rollback, and optionally keep it running in the background or at login. No BetterDisplay required.

## Get started

[Download v0.1.0](https://github.com/koonweee/hidpi-cli/releases/tag/v0.1.0) for **Apple silicon, macOS 27+**. Extract it and run `./hidpi`. Keep the included helper and license files together. Binaries are unsigned and not notarized.

Or build with Apple's Command Line Tools:

```sh
git clone https://github.com/koonweee/hidpi-cli.git
cd hidpi-cli
sh build.sh
./build/hidpi
```

Choose **Change resolution**. Virtual modes offer a 20-second trial, background use, or startup at login. All other actions are under **More options**.

## Useful commands

```sh
hidpi --list             # List resolutions
hidpi status             # Check the background helper
hidpi stop               # Restore now; keep login preference
hidpi disable            # Restore and disable login startup
hidpi uninstall          # Restore and remove installed files
hidpi --help             # All commands
```

After installation, use `~/.local/bin/hidpi` if it isn't on your PATH.

Virtual modes require a running helper and use private Apple APIs that macOS updates can break. Other hardware and macOS versions remain unverified.

## License

[MIT](LICENSE). Virtual-display code is adapted from [pasky/hidpi-mirror](https://github.com/pasky/hidpi-mirror), © 2026 Petr Baudis. See [third-party notices](THIRD_PARTY_NOTICES.md).
