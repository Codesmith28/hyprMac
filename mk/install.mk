# Install / uninstall with exact rollback. Owned by the install workstream.
.PHONY: install uninstall verify-rollback scripts-test
install: app                                   ## install to ~/Applications with recorded, reversible system changes
	APP_SRC=$(abspath $(APP_BUNDLE)) scripts/install.sh

uninstall:                                     ## reverse every recorded install action, then verify rollback
	scripts/uninstall.sh

verify-rollback:                               ## diff current state against the pre-install snapshot
	scripts/verify_rollback.sh

scripts-test:                                  ## sandboxed tests for install/uninstall (fake HOME + shims)
	scripts/tests/run.sh
