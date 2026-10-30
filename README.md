# Cue

A native tvOS media player for Stremio add-ons, with Nuvio account sync.
Pre-release (0.9); the player is being replaced.

Requires tvOS 17 or later.

## Build

Requires Xcode with the tvOS platform and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cp Secrets.example.swift Cue/Secrets.swift   # keys are optional
xcodegen generate
open Cue.xcodeproj
```

## License

GPLv3. Forked from [Orivio TV](https://github.com/prehakanson-art/OrivioTVAppleTV).
