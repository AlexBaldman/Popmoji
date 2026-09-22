# Custom Content + Keyboard Roadmap

> Product name is intentionally treated as a replaceable codename while branding is being reconsidered.

## Product model

The app should treat every expressive item as a canonical `ContentItem`, then let providers supply content and insertion adapters decide how that item can be used on a given surface.

### Providers

- Unicode emoji
- Custom image emoji
- Stickers
- GIFs
- Symbols
- Kaomoji
- Generated/user-created packs

### Insertion modes

- `plainText` — true Unicode/text insertion
- `richImage` — insert an image into apps that accept rich pasteboard content
- `adaptiveImageGlyph` — Apple adaptive glyph path where the OS/app supports it
- `clipboard` — copy an image or rich payload for a user paste action
- `share` — hand content to a share sheet / host app integration

This prevents the picker UI from caring whether an item is a Unicode scalar, PNG, animated asset, sticker, or future content type.

## Pickleball pack: first custom-content test

`Sources/Popmoji/Resources/ContentPacks/pickleball.json` is the first provider-neutral custom pack manifest.

Initial items:

- pickleball ball
- paddle
- dink
- hot shot
- pickleball love
- scoreboard
- pickle vibes

The current manifest reserves asset paths. Next asset pass should export each icon as an individual transparent image and validate it at keyboard/picker sizes.

## macOS vertical slice

1. Add a bundled content-pack loader.
2. Merge Unicode + custom content into one ranked search result stream.
3. Render image-backed results in the existing picker.
4. Add a macOS rich-image pasteboard adapter.
5. Fall back to copy-to-clipboard when the foreground app does not accept direct rich insertion.
6. Preserve the existing Unicode text insertion path unchanged.

A custom image should never masquerade as a Unicode character. The insertion adapter should make the distinction explicit.

## iPhone keyboard

Create an iOS containing app plus a Custom Keyboard Extension using `UIInputViewController`.

Apple's public keyboard API inserts text through `textDocumentProxy.insertText(_:)` as an unattributed string. That means true Unicode emoji can be inserted directly, but arbitrary custom images cannot be inserted as ordinary text through that API.

For custom image emoji, support several delivery paths:

1. **Clipboard mode** — copy the selected image/rich payload, then guide the user to paste. `UIPasteboard` access requires Full Access for a third-party keyboard.
2. **Share mode** — open/hand off to the containing app or an appropriate extension for richer content.
3. **Messages-specific integration** — consider a Messages extension/sticker experience for first-class image sending inside Messages.
4. **Adaptive image glyph experiments** — preserve and support Apple's adaptive image glyph data where available, but do not assume arbitrary third-party images can be turned into universal Genmoji-style text glyphs through a public keyboard API.

### Privacy stance

The keyboard should work offline by default. Only request Full Access when the user explicitly enables features that require it, such as shared mutable storage, network-backed content, or pasteboard-based image sending. Explain exactly why the permission is needed.

## Unicode submission track

Unicode encoding is a separate product track from custom packs.

As of September 2026:

- Unicode's 2026 emoji submission window closed July 31, 2026.
- Submissions are expected to reopen in 2027.
- A proposal needs empirical frequency evidence and open/licensable example artwork.
- Required proposal examples include color and black-and-white images at 18×18 and 72×72 pixels.
- Logos, brands, specific people, exact-image requests, and several other categories are automatically declined.

A pickleball proposal should be researched against existing requests/decisions before drafting. The app does not need to wait for Unicode acceptance: the custom pack can ship independently.

## Architecture rule

Search results resolve to canonical content. The platform chooses the best available representation at insertion time.

Examples:

- `pickleball` on macOS rich-text app → custom image
- `pickleball` on iOS keyboard → clipboard/share image path
- future Unicode pickleball character → direct text insertion everywhere
- same canonical item can expose all of those representations without duplicating search metadata

## Next implementation slice

Wire the bundled pack loader into the picker on macOS and make one pickleball asset searchable and sendable end-to-end before adding a larger content-creation studio. That one completed path should earn the abstraction before the architecture grows further.

### Proof implemented

- `pickleball:ball` ships as a transparent bundled PNG.
- The bundled provider publishes only manifest entries whose payloads exist, so the six reserved concepts do not create dead search results.
- The picker searches Unicode and custom content through the shared `ContentItem` model and renders the image-backed result.
- Choosing the ball uses `MacOSImageInsertionAdapter`: it copies an image pasteboard payload, attempts rich paste into the captured app when Accessibility is available, and leaves the payload ready for manual paste as the fallback.
- Unicode selection still uses the existing Unicode keyboard-event insertion path.
- Missing or invalid optional packs are logged and skipped; Unicode and other valid packs remain available.
- Image copy failures appear in the picker footer or, after choosing an item hides the picker, in an alert. The copied status is shown only after the image clipboard write succeeds.
- The vertical-slice tests cover pack loading, search and alias discovery, image decoding, insertion planning, an isolated pasteboard round trip, and missing/corrupt payloads and rejected writes.

### Focused review validation

Run on macOS:

```sh
swift test --filter CustomContentVerticalSliceTests
bash scripts/build.sh
```

The macOS validation workflow runs both commands and checks that the signed app contains `ContentPacks/pickleball.json` and `ContentPacks/pickleball/ball.png`. The package copies the content-pack directory intact because the loader resolves those relative paths.

Manual smoke checks (still required for host-app behavior):

1. Launch the built app, search `pickleball` and `pb_ball`, and confirm the ball preview appears. Reserved assets must not appear.
2. Copy the ball and paste it into Notes. Choose it with a rich-text target active, then confirm manual `⌘V` still works if automatic paste is unavailable. Adapter success means the clipboard payload is ready; it does not confirm the target accepted the image.
3. Confirm Unicode search, a custom Unicode alias, and Unicode insertion still work.
4. In a disposable resource-bundle copy, remove or corrupt the pickleball manifest before launch. The picker must still open and find Unicode results. After loading a valid pack, remove or corrupt its image: copying must show failure instead of “Copied”; choosing it with no target must show an alert after the picker hides. Rebuild afterward to restore signed resources. Rejected pasteboard writes are covered by an injected test writer.

Review status: CodeRabbit's last published report on `a230389` warned of 3.45% docstring coverage (80% required, 29 touched functions). The cleanup documents the touched functions and failure contracts; the authoritative coverage result remains pending a fresh CodeRabbit review. Linux resource/static checks do not establish that the AppKit build, XCTest suite, or manual smoke checks pass.

## Primary references

- Apple: Creating a custom keyboard — https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard
- Apple: UIInputViewController — https://developer.apple.com/documentation/uikit/uiinputviewcontroller
- Apple: Configuring open access for a custom keyboard — https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard
- Apple: NSAdaptiveImageGlyph — https://developer.apple.com/documentation/uikit/nsadaptiveimageglyph
- Unicode: Emoji proposal guidelines — https://www.unicode.org/emoji/proposals.html
