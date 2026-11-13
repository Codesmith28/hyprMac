# Install / uninstall with exact rollback. Owned by the install workstream.
# `make sign-identity` is an opt-in local code-signing identity (see docs/LIMITATIONS.md).
# `make install DRY_RUN=1` / `make uninstall DRY_RUN=1` print every action
# without performing it; `make preflight` is a read-only report for this Mac.
.PHONY: install update uninstall verify-rollback scripts-test preflight sign-identity sign-identity-remove sign-identity-status
INSTALL_FLAGS := $(if $(filter 1 yes true,$(DRY_RUN)),--dry-run)

install: app                                   ## install to ~/Applications with recorded, reversible system changes (DRY_RUN=1: print only)
	APP_SRC=$(abspath $(APP_BUNDLE)) scripts/install.sh $(INSTALL_FLAGS)

update: app                                    ## update ~/Applications/hyprMac.app and reload
	APP_SRC=$(abspath $(APP_BUNDLE)) scripts/install.sh $(INSTALL_FLAGS)

uninstall:                                     ## reverse every recorded install action, then verify rollback (DRY_RUN=1: print only)
	scripts/uninstall.sh $(INSTALL_FLAGS)

preflight:                                     ## read-only: show what `make install` would change on this Mac
	APP_SRC=$(abspath $(APP_BUNDLE)) scripts/install.sh --preflight

verify-rollback:                               ## diff current state against the pre-install snapshot
	scripts/verify_rollback.sh

sign-identity:                                 ## opt-in: create the "hyprMac Local Signing" identity so the Accessibility grant survives upgrades (DRY_RUN=1: print only)
	scripts/sign_identity.sh create $(INSTALL_FLAGS)

sign-identity-remove:                          ## remove the "hyprMac Local Signing" identity (only if sign-identity made it)
	scripts/sign_identity.sh remove $(INSTALL_FLAGS)

sign-identity-status:                          ## print the local signing identity's SHA-1, or "absent"
	scripts/sign_identity.sh status

scripts-test:                                  ## sandboxed tests for install/uninstall (fake HOME + shims) and the release helpers
	scripts/tests/run.sh
	scripts/tests/release.sh
