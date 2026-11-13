# Homebrew cask

`hyprmac.rb` is a cask template. It points at the zip that the [release workflow](../../.github/workflows/release.yml) attaches to each GitHub release (`hyprMac-<version>.zip`). Nothing here is published for you: you host the cask in your own tap.

## Publish it to your own tap
Do this once per release, after the GitHub release exists. Nothing below is automated.

1. Create a tap repo named `homebrew-<something>` (for example `Codesmith28/homebrew-tap`) and clone it.
2. Download the release zip, or just its `.sha256` file, from the release page.
3. Fill in the template from the hyprMac checkout:
   ```sh
   scripts/release/cask.sh --version 0.3.0 --zip ~/Downloads/hyprMac-0.3.0.zip \
       -o ../homebrew-tap/Casks/hyprmac.rb
   # or: --sha256-file ~/Downloads/hyprMac-0.3.0.zip.sha256   /   --sha256 <hex>
   ```
4. Commit and push the tap.
5. Install from it:
   ```sh
   brew tap codesmith28/tap
   brew install --cask hyprmac
   ```

`brew upgrade --cask hyprmac` picks up the next version after you repeat step 3 and push.

## Notes
- The app is **ad-hoc signed and not notarized**. The cask clears the quarantine flag in `postflight`, so Gatekeeper doesn't block it. macOS asks for Accessibility again after every upgrade, because an ad-hoc signature changes with each build.
- The cask installs only the app, into `/Applications`. It does not run `make install`, so it doesn't add the ⌥8/⌥9 shortcuts, turn off Stage Manager or write a LaunchAgent. Add hyprMac under System Settings ▸ General ▸ Login Items to start it at login, and turn Stage Manager off yourself.
- `brew uninstall --zap --cask hyprmac` also removes the config, preferences, caches and logs.
- Don't change the `version` and `sha256` lines by hand. `scripts/release/cask.sh` rewrites them and refuses a bad hash.
