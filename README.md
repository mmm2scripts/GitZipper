# GitZipper (rebuilt)
Black & white SwiftUI app, iPhone + iPad (3-column split view).
Features: repo browser, folders, search, preview (code with line numbers / markdown / images), edit & save (commits to default branch), multi-select delete (one commit), new file, upload ZIP, download repo ZIP.

## Build the IPA (no Mac needed)
1. Push this folder to a GitHub repo.
2. Actions → "Build unsigned IPA" → download the artifact.
3. Sign/install with AltStore, Sideloadly, TrollStore, etc.

Or on a Mac: `brew install xcodegen && xcodegen generate && open GitZipper.xcodeproj`
