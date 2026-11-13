---

### Install
Download `hyprMac-{{VERSION}}.zip`, unzip it and move `hyprMac.app` to `~/Applications`. Or use Homebrew (see `packaging/homebrew/`).

`sha256: {{SHA256}}`

### Signing
This build is **ad-hoc signed**, not notarized, and downloaded copies are quarantined by macOS. Clear that once with `xattr -dr com.apple.quarantine ~/Applications/hyprMac.app`, or right-click ▸ Open. Grant Accessibility under System Settings ▸ Privacy & Security.

Ad-hoc signatures change with every build, so macOS asks for Accessibility again after each upgrade. Building from source? `make sign-identity` creates a local signing identity so the grant survives upgrades.
