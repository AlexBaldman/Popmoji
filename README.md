# Popmoji

Popmoji is a small macOS menu bar app for putting emoji into conversations quickly, anywhere you type.

## Use it

- Type `:emoji` in any text field and choose a suggestion with ↑/↓ and Enter.
- Press **⌃⌥Space** to open the floating picker.
- Search by name, feeling, object, or category.
- Right-click an emoji to favorite it or create a custom alias.
- Use **⌘C** in the picker to copy an emoji without Accessibility access.

The first time you use insertion, open Preferences and enable Popmoji in **System Settings → Privacy & Security → Accessibility**. Popmoji stores preferences locally and makes no network requests at runtime.

## Build

```sh
bash scripts/build.sh
open dist/Popmoji.app
```

## Install from the command line

```sh
curl -fsSL https://raw.githubusercontent.com/AlexBaldman/Popmoji/main/install.sh | bash
```

The installer puts Popmoji in `/Applications` when possible, falls back to `~/Applications`, verifies the app signature, and opens it. To install a specific release or location:

```sh
POPMOJI_VERSION=0.1.1 POPMOJI_INSTALL_DIR="$HOME/Applications" bash install.sh
```

Requires macOS 13 or newer and Swift 5.9+. The emoji metadata is bundled from [GitHub’s gemoji](https://github.com/github/gemoji) under its MIT license.

## License

Popmoji source is released under the MIT License. See `Sources/Popmoji/Resources/GEMOJI-LICENSE.txt` for the bundled emoji metadata license.
