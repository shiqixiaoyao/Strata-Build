# Built-in host plugins

These two dylibs ship inside `LiveContainer.app/Frameworks` and are injected into the
LiveContainer host process by `LCBootstrap.m`. Both are loaded only when the host is
already running its own frameworks, and both use their own `__attribute__((constructor))`
entry point, so no Swift bridging is required.

| File | Upstream | Version | Licence |
|---|---|---|---|
| `LCGridLayout.dylib` | https://github.com/Kan9e/LCGridLayout | v24 | AGPL-3.0 |
| `LCFloatingMenu.dylib` | https://github.com/dompling/LC-SS-widget-export (branch `lcss-original`) | 1.0.40 | AGPL-3.0 |

`LCGridLayout.m` is the matching source for the grid dylib (AGPL-3.0 §6 requires the
source to travel with the binary). The floating-menu source lives in the upstream
repository above, at `LCFloatingMenu/LCFloatingMenu.m` plus `LCOrbit/`.

Deliberately **not** bundled: `SideStoreTranslator.dylib` and its `zh-Hans.json`, which
are a separate SideStore translation package published in the same upstream release.

Both are dlopen-ed by `LCBootstrap`. `LCFloatingMenu` only mounts its overlay when
`LCOrbitHost.isHostUI` says so, which requires the developer key `LCLoadTweaksToSelf`
in LC's own defaults — a leftover from the upstream install path (dylib in
`Documents/Tweaks`, loaded by `TweakLoader`). The built-in loader sets that key before
dlopen, and skips the native all-tweaks-into-host path while this plugin is enabled so
a stray global tweak cannot crash the host.
