# External dependencies (Lua 5.4.7) fetched on-demand with SHA256 verification.
LUA_DIR := third_party/lua-5.4.7

# Fetch on-demand before source wildcard expansion unless running clean or help targets
ifeq ($(filter clean clean-deps distclean help,$(MAKECMDGOALS)),)
  ifeq ($(shell test -f $(LUA_DIR)/.fetched && test -f $(LUA_DIR)/lua.h && echo 1),)
    _FETCH_STATUS := $(shell ./scripts/fetch_lua.sh $(LUA_DIR) >&2; echo $$?)
    ifneq ($(_FETCH_STATUS),0)
      $(error Failed to fetch Lua dependency. Check your network or run 'make deps'.)
    endif
  endif
endif

.PHONY: deps clean-deps distclean
deps:                                          ## fetch and verify external dependencies (Lua)
	@./scripts/fetch_lua.sh $(LUA_DIR)

clean-deps:                                    ## remove downloaded external dependencies
	rm -rf $(LUA_DIR)

distclean: clean clean-deps                    ## remove all build products and downloaded dependencies
