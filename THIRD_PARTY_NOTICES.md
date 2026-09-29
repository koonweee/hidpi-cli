# Third-party notices

## hidpi-mirror

Virtual-display support in `src/hidpi-test.m` incorporates source adapted from
[pasky/hidpi-mirror](https://github.com/pasky/hidpi-mirror), copyright (c) 2026
Petr Baudis, licensed under the MIT License.

Adaptations include the private CoreGraphics declarations and virtual-display
mode construction. This project adds its own menu, native mode selection,
independent supervisor/controller, trial restoration, verification records,
and service management.

The full upstream notice is preserved in [licenses/hidpi-mirror-MIT.txt](licenses/hidpi-mirror-MIT.txt).
The build copies it beside the executables as `hidpi-test-LICENSE.txt`; keep
that notice with binary distributions. The installer also copies it.

## Technical references

The fresh-process mode-query workaround was informed by the
[go-macos/virtualdisplay technical findings](https://pkg.go.dev/github.com/go-macos/virtualdisplay).
No source from that package was incorporated.

Apple frameworks and launchd are operating-system facilities, not bundled
third-party libraries. Custom display support uses undocumented Apple APIs.
