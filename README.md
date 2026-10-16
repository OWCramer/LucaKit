# LucaKit

Shiori's Luca System engine (Prototype; Summer Pockets REFLECTION BLUE): PAK archives, CZ images, the game's fonts and script bytecode, and an interpreter, in Swift. Part of [Shiori](https://github.com/OWCramer/shiori).

It plays games you own; no game content is included.

- `Sources/LucaKit`: the formats and the interpreter.
- `luca-cli`: lists archives, dumps scripts and renders frames on the Mac.
- `Scripts/luca`: builds libvpx's VP9 decoder (`Vendor/ShioriVPX.xcframework`, static, iOS and tvOS) for the game's WebM movies, which the app links.

```sh
swift build
swift test
Scripts/luca/fetch-vpx.sh && Scripts/luca/build-ios-vpx.sh
```

## Licence

LucaKit's own code is under the [Mozilla Public License 2.0](LICENSE). Its formats follow LuckSystem's notes (MIT, wetor); opcode names come from its `SummerPocketsRB.txt`. libvpx (BSD-3 with a patent grant) is fetched and built, never committed.
