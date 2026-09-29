# hidpi-cli

A small macOS terminal menu for native and virtual HiDPI resolutions.
No BetterDisplay installation, third-party packages, or background service
is required for native modes.

Custom virtual modes use an optional helper. Choose a resolution, try it with
automatic rollback, then keep it running in the background or restore it at login.

## Download

The [v0.1.0 prerelease](https://github.com/koonweee/hidpi-cli/releases/tag/v0.1.0)
includes compiled **Apple-silicon executables requiring macOS 27 or later**,
plus license notices and SHA-256 checksums. Extract the archive, then run
`./hidpi` from the extracted folder. Keep `hidpi-test` and its license beside it.
The binaries are not Developer ID signed or notarized. Build from source below
if you prefer; compatibility with other macOS versions remains unverified.

## Build and run

Requires macOS and Apple's Command Line Tools (`xcode-select --install`).
Development and live display testing were performed on Apple silicon with
macOS 27. Other hardware and macOS versions are not yet verified.

```sh
git clone https://github.com/koonweee/hidpi-cli.git
cd hidpi-cli
sh build.sh
./build/hidpi
```

The opening menu has three actions:

```text
1. Change resolution
2. Restore normal display and turn off login startup
3. More options…
```

Start with **Change resolution**. Native modes apply directly. For a virtual
size, choose a 20-second trial, background use until logout, or use at login.
An untested size must pass the trial before background startup. Let the trial
countdown finish to continue setup; cancelling aborts setup.

All explicit commands, including diagnostics and uninstall, are available
under **More options**. `q` exits the current screen. Ctrl-C stops an active
foreground trial and requests restoration.

## Background installation

The guided flow installs the helper when needed. Manual commands are also available:

```sh
./build/hidpi install
~/.local/bin/hidpi enable 1920 1200 # Start now and restore at login
~/.local/bin/hidpi status
~/.local/bin/hidpi stop            # Restore now; retain login preference
~/.local/bin/hidpi disable         # Restore now and disable login startup
~/.local/bin/hidpi start           # Resume the saved choice
~/.local/bin/hidpi uninstall       # Restore and remove installed files
```

Test a virtual size in the foreground once before starting it in the background.
`start` and `enable` accept `[width height [display-ID]]`. With no dimensions,
they reuse the saved choice, or default to 1920 × 1200 on the sole external monitor.
For multiple monitors, get IDs from `hidpi --list`. Saved choices use monitor UUIDs
so changing numeric IDs after a restart do not select another monitor.

Installation is per user and needs no sudo:

- Executables, state, and logs: `~/Library/Application Support/hidpi/`
- LaunchAgent: `~/Library/LaunchAgents/local.hidpi.helper.plist`
- CLI shortcut: `~/.local/bin/hidpi` (shell PATH is not modified)

Updates preserve a running display session. New helper code takes effect on its
next start. Uninstall removes owned files and preserves unrelated files and your
source checkout. Keep both executables and their license notice together when
distributing a build.

## Commands

| Command | Purpose |
| --- | --- |
| `hidpi` / `hidpi --menu` | Guided menu |
| `hidpi --pick` | Direct native/virtual resolution picker |
| `hidpi --list` | List native modes and virtual candidates without changes |
| `hidpi --dry-run` | Preview a selection without applying it |
| `hidpi --custom-trial` | Test a custom virtual size |
| `hidpi install` | Install or update per-user files |
| `hidpi start [width height [ID]]` | Start in background; preserve login preference |
| `hidpi enable [width height [ID]]` | Start now and at future logins |
| `hidpi stop` | Stop and restore; retain login preference |
| `hidpi disable` | Stop, restore, and disable login startup |
| `hidpi status` | Show service state and log location |
| `hidpi uninstall` | Stop, restore, and remove installed files |

## How it works

Native options are desktop-usable CoreGraphics modes whose backing pixel sizes
exceed their logical desktop sizes. Virtual candidates use common widths matching
the inferred panel aspect ratio. They are suggestions, not detected guarantees of
support. Candidate generation excludes sizes already offered natively and is
limited to 2560 × 1600 logical pixels; the virtual helper requests 60 Hz.

For virtual modes, one process owns a `CGVirtualDisplay`, a fresh process queries
and configures it, and a separate supervisor enforces startup/trial deadlines.
The fresh process avoids a CoreGraphics cache issue where the creating process
can see the new display but cannot read its modes. The physical monitor mirrors
the virtual desktop. The helper must remain alive while using that desktop.

The supervisor saves the existing display modes and positions, verifies the
requested 2× backing dimensions, and restores on exit. A successful test is
remembered per monitor UUID, macOS version/build, and requested size. Listing
candidates creates no virtual displays. Updating macOS requires re-verification.

## Limits and troubleshooting

- Virtual display creation uses **private Apple APIs**. macOS updates can break it.
- This increases rendering resolution, not the monitor's physical pixel count.
- Existing mirroring must be disabled before a virtual trial. Individual window
  positions are not restored. Disconnecting monitors can prevent exact restoration.
- Login startup runs after user login, not on the FileVault or login screen.
  It waits up to 30 seconds for the saved monitor. There are no restart loops;
  connecting a monitor later requires `hidpi start`.
- Cable/KVM reconnect handling is intentionally limited compared with upstream.
- Setup failures are logged to `~/Library/Application Support/hidpi/service.log`.
  Use `hidpi status` first. Check System Settings → Displays if restoration fails.

`HIDPI_STATE_DIR` overrides foreground verification-state storage. The installed
LaunchAgent uses its installation directory for state.

## Tests

```sh
./build/hidpi --self-test
./build/hidpi --service-self-test
./build/hidpi-test --self-test
python3 tests/menu_pty.py
```

These check candidate generation, lifecycle behavior against simulated launchd,
updates preserving an active job, timeout handling, watchdog process cleanup,
and menu input under a real controlling terminal. They do not change display
modes or start/stop a real LaunchAgent. Live display transitions, physical
disconnects, and login/reboot behavior require manual hardware testing.

## License and attribution

MIT; see [LICENSE](LICENSE). Virtual-display support incorporates code adapted
from [pasky/hidpi-mirror](https://github.com/pasky/hidpi-mirror),
© 2026 Petr Baudis, MIT licensed. Its full notice is retained in
[licenses/hidpi-mirror-MIT.txt](licenses/hidpi-mirror-MIT.txt).
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for details.
