# zfiler

An independent Wayland file manager with directory browsing, bounded navigation history, filtering, sorting, file operations and Trash management. Icons, disk capacity and font discovery run asynchronously.

## Build and run

Use the Nalume Zig 0.17 development toolchain with native Wayland/EGL/OpenGL, xkbcommon, Fontconfig and rendering dependencies.

```sh
zig build
zig build run
zig build test
```

The installed executable is `zig-out/bin/zfiler`, with Wayland app id `dev.nalume.zfiler`. Running requires a Wayland compositor; `zig build test` runs the state regressions without one.

## Dependencies

Clone these independent repositories alongside this one: `dvui`, `views`, `file-operations`, `system-fonts`, `system-icons`, and `nalume-ui`, plus their transitive dependencies. There is no dependency on a desktop shell repository or its sources.

The app uses `views.Manager` for connection and window lifecycle. Every DVUI-bearing dependency receives identical backend options, maintaining one DVUI module instance per graph.

## Font ownership

The shared `nalume_ui.fonts.Fonts` runtime owns asynchronous discovery, immutable generation registries and per-window leases, backed by the GUI-free system-fonts service. The app attaches hooks before creating its window and applies the shared type scale after theme installation. Views release leases after their DVUI windows are destroyed; the Manager is destroyed before Fonts. Preferences use the `zfiler` application directory under the XDG config directory. Font runtime regressions live in nalume-ui and run with `zig build test -Dbackend=testing -Dnative-types=true`.
