# hyprMac — top-level build. `make help` lists targets.
SHELL        := /bin/bash
.DEFAULT_GOAL := build
.SUFFIXES:

BUILD   ?= build
MODE    ?= release# release | asan
CC      := clang
CXX     := clang++
AR      := ar

ifeq ($(strip $(MODE)),asan)
  OPT := -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all
  LDSAN := -fsanitize=address,undefined
else
  OPT := -O2 -g
  LDSAN :=
endif

OUT      := $(BUILD)/$(strip $(MODE))
OBJDIR   := $(OUT)/obj
LIB      := $(OUT)/libhyprcore.a

include mk/deps.mk
CPPFLAGS := -Icore/include -I$(LUA_DIR) -Ithird_party/doctest -MMD -MP
CXXFLAGS := -std=c++20 $(OPT) -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wno-sign-conversion -mmacosx-version-min=14.0
CFLAGS   := -std=c99 $(OPT) -DLUA_USE_MACOSX -w -mmacosx-version-min=14.0

# Sources are discovered by wildcard so parallel workstreams never edit this file.
CORE_SRCS := $(wildcard core/src/*.cpp)
LUA_SRCS  := $(wildcard $(LUA_DIR)/*.c)
TEST_SRCS := $(wildcard core/tests/*.cpp)

CORE_OBJS := $(CORE_SRCS:%.cpp=$(OBJDIR)/%.o)
LUA_OBJS  := $(LUA_SRCS:%.c=$(OBJDIR)/%.o)
TEST_OBJS := $(TEST_SRCS:%.cpp=$(OBJDIR)/%.o)
TEST_BIN  := $(OUT)/core_tests

$(OBJDIR)/%.o: %.cpp
	@mkdir -p $(@D)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

$(OBJDIR)/%.o: %.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(LUA_DIR) -c $< -o $@

$(LIB): $(CORE_OBJS) $(LUA_OBJS)
	@mkdir -p $(@D)
	@rm -f $@
	$(AR) rcs $@ $^

$(TEST_BIN): $(TEST_OBJS) $(LIB)
	$(CXX) $(CXXFLAGS) $(LDSAN) $(TEST_OBJS) $(LIB) -o $@

-include $(CORE_OBJS:.o=.d) $(TEST_OBJS:.o=.d)

.PHONY: core core-test test-asan
core: $(LIB)                                   ## build libhyprcore.a (C++ core + Lua)
core-test: $(TEST_BIN)                         ## run C++ core + config tests
	$(TEST_BIN) $(TEST_ARGS)
test-asan:                                     ## run core tests under ASan/UBSan
	$(MAKE) MODE=asan core-test

include mk/swift.mk
include mk/install.mk
include mk/bench.mk

.PHONY: build test clean help
build: core app                                ## build everything (core + hyprMac.app)
test: core-test swift-test scripts-test        ## all tests that need no permissions
clean:                                         ## remove build products (never touches the system)
	rm -rf $(BUILD) macos/.build
help:
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | sort | column -t -s $$'\t'
