# Core benchmark (owned by the core workstream). Built with the current MODE flags;
# meaningful numbers need the default MODE=release.
BENCH_SRCS := $(wildcard core/bench/*.cpp)
BENCH_OBJS := $(BENCH_SRCS:%.cpp=$(OBJDIR)/%.o)
BENCH_BIN  := $(OUT)/core_bench

$(BENCH_BIN): $(BENCH_OBJS) $(LIB)
	$(CXX) $(CXXFLAGS) $(LDSAN) $(BENCH_OBJS) $(LIB) -o $@

-include $(BENCH_OBJS:.o=.d)

.PHONY: bench
bench: $(BENCH_BIN)                            ## reconcile+layout latency benchmark (1/10/50/200 windows, 10k random)
	$(BENCH_BIN) $(BENCH_ARGS)
