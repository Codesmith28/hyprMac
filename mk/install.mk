# Install / uninstall with exact rollback. Owned by the install workstream.
# `make install DRY_RUN=1` / `make uninstall DRY_RUN=1` print every action
# without performing it; `make preflight` is a read-only report for this Mac.
.PHONY: install uninstall verify-rollback scripts-test preflight
INSTALL_FLAGS := $(if $(filter 1 yes true,$(DRY_RUN)),--dry-run)

install: app                                   ## install to ~/Applications with recorded, reversible system changes (DRY_RUN=1: print only)
	APP_SRC=$(abspath $(APP_BUNDLE)) scripts/install.sh $(INSTALL_FLAGS)

uninstall:                                     ## reverse every recorded install action, then verify rollback (DRY_RUN=1: print only)
	scripts/uninstall.sh $(INSTALL_FLAGS)

preflight:                                     ## read-only: show what `make install` would change on this Mac
	APP_SRC=$(abspath $(APP_BUNDLE)) scripts/install.sh --preflight

verify-rollback:                               ## diff current state against the pre-install snapshot
	scripts/verify_rollback.sh

scripts-test:                                  ## sandboxed tests for install/uninstall (fake HOME + shims)
	scripts/tests/run.sh
