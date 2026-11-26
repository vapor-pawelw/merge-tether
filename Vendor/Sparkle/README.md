# Sparkle 2.10.1

`Sparkle.xcframework` contains the universal macOS framework from the official
[Sparkle for Swift Package Manager release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1).
The ZIP's SHA-256 is `4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a`.
The matching dSYMs are available in that release. The packaged framework is
unmodified. Its enclosing XCFramework metadata omits the dSYM path.

Keep framework symlinks and executable bits when replacing it. Update the
release tooling version and archive checksum in `scripts/generate-update-feed.sh`
at the same time. [Sparkle-LICENSE.txt](Sparkle-LICENSE.txt) is bundled with the Mac app.
