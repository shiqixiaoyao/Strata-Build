# Built-in plugins

Two things ship in this fork:

| What | Where | Upstream | Version | Licence |
|---|---|---|---|---|
| `LCGridLayout.dylib` | `LiveContainer.app/Frameworks`, dlopen-ed by `LCBootstrap.m` | https://github.com/Kan9e/LCGridLayout | v24 | AGPL-3.0 |
| floating menu + Orbit | compiled into `TweakLoader.dylib` | https://github.com/dompling/LC-SS-widget-export (branch `lcss-original`) | 1.0.48 | AGPL-3.0 |

`LCGridLayout.m` is the matching source for the grid dylib (AGPL-3.0 §6 requires the
source to travel with the binary), and CI rebuilds the dylib from it on every run so the
two cannot drift. The floating-menu sources live in `Orbit/` (copied from the upstream
`LCOrbit/Core/` and `LCFloatingMenu/LCFloatingMenu.m`, headers flattened to one
directory); CI compiles them as part of the `TweakLoader` target.

## Why the menu lives in TweakLoader

v19 built it that way (30 `LCOrbit*` classes inside `TweakLoader.dylib`, no standalone
dylib), and that is the only arrangement where the menu has a real `LCOrbitCore` to
register with inside a guest process. A standalone `LCFloatingMenu.dylib` dlopen-ed from
the host never reaches the apps it launches.

## Host vs guest

`TweakLoader` is only loaded into a guest process. `LCBootstrap` does **not** set
`LCLoadTweaksToSelf`, so LiveContainer's own process never loads it either: the menu
appears inside the apps you launch, not in LC's own UI. Orbit's host branch is 4.0 host
code and crashes a 3.9 host on launch — 3.9.7 proved that. `LCBootstrap` still performs a
one-shot migration that clears any `LCLoadTweaksToSelf=YES` left behind by that build.

## Local patches on top of upstream

- The orientation-force layer (281 lines) is deleted: it pinned the mask to
  `Portrait|LandscapeRight` and rewrote every window's `frame`/`bounds` on
  `layoutSubviews`, which fights `UIWindowScene` on iOS 13+ and shows up as
  right-landscape content skewed to one side with black bars on the other. Only the
  idle-timer swizzle survives.
- The two now-dead switches (`unlockOrientation`, `lockBanRightLandscape`) are removed
  from the settings page, together with their reset entries.

Deliberately **not** bundled: `SideStoreTranslator.dylib` and its `zh-Hans.json`; the
store translation is shipped as a merged `zh-Hans.lproj/Localizable.strings` instead.
