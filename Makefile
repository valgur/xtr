-include conanbuildinfo.mak

PREFIX ?= /usr/local
EXCEPTIONS ?= 1
SANITIZER ?= 0
COVERAGE ?= 0
PIC ?= 0

GOOGLE_BENCH_CPPFLAGS = $(addprefix -isystem, $(CONAN_INCLUDE_DIRS_BENCHMARK) $(GOOGLE_BENCH_INCLUDE_DIR))
GOOGLE_BENCH_LDFLAGS = $(addprefix -L, $(CONAN_LIB_DIRS_BENCHMARK) $(GOOGLE_BENCH_LIB_DIR))
CATCH2_CPPFLAGS = $(addprefix -isystem, $(CONAN_INCLUDE_DIRS_CATCH2) $(CATCH2_INCLUDE_DIR))
FMT_CPPFLAGS = $(addprefix -isystem, $(CONAN_INCLUDE_DIRS_FMT) $(FMT_INCLUDE_DIR))
FMT_LDFLAGS = $(addprefix -L, $(CONAN_LIB_DIRS_FMT) $(FMT_LIB_DIR))

BUILD_DIR := build/$(CXX)

CXXFLAGS = \
	-std=c++2a -Wall -Wextra -Wconversion -Wshadow -Wcast-qual -Wformat=2 \
	-pedantic -pipe -fno-rtti -pthread
CPPFLAGS = -MMD -MP -I include $(FMT_CPPFLAGS)
LDFLAGS = -fuse-ld=gold
LDLIBS = -lxtr

DEBUG_CXXFLAGS = -O0 -ggdb -ftrapv
DEBUG_CPPFLAGS = -DXTR_ENABLE_TEST_STATIC_ASSERTIONS

OPT_CXXFLAGS = -O3 -march=native -flto
OPT_CPPFLAGS = -DNDEBUG 

TEST_CPPFLAGS = $(CATCH2_CPPFLAGS) 
TEST_LDFLAGS = -L $(BUILD_DIR) $(FMT_LDFLAGS)

BENCH_CPPFLAGS = $(GOOGLE_BENCH_CPPFLAGS)
BENCH_LDFLAGS = -L $(BUILD_DIR) $(GOOGLE_BENCH_LDFLAGS) $(FMT_LDFLAGS)
BENCH_LDLIBS = -lbenchmark

COVERAGE_CXXFLAGS = --coverage -DNDEBUG

SANITIZER_CXXFLAGS = -fno-omit-frame-pointer -fsanitize=address -fsanitize=undefined

# Use the libfmt submodule if it is present and no include directory for
# libfmt has been configured.
ifeq ($(FMT_CPPFLAGS),)
	ifneq ($(wildcard third_party/fmt/include),)
		SUBMODULES_FLAG := 1
	endif
endif
ifneq ($(SUBMODULES_FLAG),)
	FMT_CPPFLAGS += -DFMT_HEADER_ONLY
	CPPFLAGS += -isystem third_party/include
else
	LDLIBS += -lfmt
endif

ifneq (,$(findstring clang,$(CXX)))
	RANLIB = llvm-ranlib
    AR = llvm-ar
else
	RANLIB = gcc-ranlib
	AR = gcc-ar
endif

ifeq ($(PIC), 1)
	CXXFLAGS += -fPIC
endif

ifeq ($(COVERAGE), 1)
	CXXFLAGS += $(COVERAGE_CXXFLAGS)
	BUILD_DIR := $(BUILD_DIR)-coverage
	COVERAGE_DATA = \
		$(SRCS:%=$(BUILD_DIR)/%.gcno) $(SRCS:%=$(BUILD_DIR)/%.gcda) \
		$(TEST_SRCS:%=$(BUILD_DIR)/%.gcno) $(TEST_SRCS:%=$(BUILD_DIR)/%.gcda)
endif

ifeq ($(DEBUG), 1)
	CXXFLAGS += $(DEBUG_CXXFLAGS)
	CPPFLAGS += $(DEBUG_CPPFLAGS)
	BUILD_DIR := $(BUILD_DIR)-debug
else
	CXXFLAGS += $(OPT_CXXFLAGS)
	CPPFLAGS += $(OPT_CPPFLAGS)
	BUILD_DIR := $(BUILD_DIR)-release
endif

ifeq ($(SANITIZER), 1)
	CXXFLAGS += $(SANITIZER_CXXFLAGS)
	BUILD_DIR := $(BUILD_DIR)-sanitizer
endif

ifeq ($(EXCEPTIONS), 0)
	CXXFLAGS += -fno-exceptions
	BUILD_DIR := $(BUILD_DIR)-no-exceptions
endif

TARGET = $(BUILD_DIR)/libxtr.a
SRCS := $(sort $(wildcard src/*.cpp))
OBJS = $(SRCS:%=$(BUILD_DIR)/%.o)

TEST_TARGET = $(BUILD_DIR)/test/test
TEST_SRCS := $(sort $(wildcard test/*.cpp))
TEST_OBJS = $(TEST_SRCS:%=$(BUILD_DIR)/%.o)

BENCH_TARGET = $(BUILD_DIR)/benchmark/benchmark
BENCH_SRCS := $(sort $(wildcard benchmark/*.cpp))
BENCH_OBJS = $(BENCH_SRCS:%=$(BUILD_DIR)/%.o)

DEPS = $(OBJS:.o=.d) $(TEST_OBJS:.o=.d)

$(TARGET): $(OBJS)
	$(AR) rc $@ $^
	$(RANLIB) $@

# LINK.cc = $(CXX) $(CXXFLAGS) $(CPPFLAGS) $(LDFLAGS) $(TARGET_ARCH)

$(TEST_TARGET): $(TARGET) $(TEST_OBJS)
	$(LINK.cc) -o $@ $(TEST_LDFLAGS) $(TEST_OBJS) -Wl,-Bstatic $(LDLIBS) -Wl,-Bdynamic

$(BENCH_TARGET): $(TARGET) $(BENCH_OBJS)
	$(LINK.cc) -o $@ $(BENCH_LDFLAGS) $(BENCH_OBJS) -Wl,-Bstatic $(LDLIBS) $(BENCH_LDLIBS) -Wl,-Bdynamic

$(OBJS): $(BUILD_DIR)/%.cpp.o: %.cpp
	@mkdir -p $(@D)
	$(CXX) -o $@ -c $(CPPFLAGS) $(CXXFLAGS) $<

$(TEST_OBJS): $(BUILD_DIR)/%.cpp.o: %.cpp
	@mkdir -p $(@D)
	$(CXX) -o $@ -c $(CPPFLAGS) $(TEST_CPPFLAGS) $(CXXFLAGS) $<

$(BENCH_OBJS): $(BUILD_DIR)/%.cpp.o: %.cpp
	@mkdir -p $(@D)
	$(CXX) -o $@ -c $(CPPFLAGS) $(BENCH_CPPFLAGS) $(CXXFLAGS) $<

all: $(TARGET)

test: $(TEST_TARGET)

run_test: $(TEST_TARGET)
	$< --order rand

benchmark: $(BENCH_TARGET)

run_benchmark: $(BENCH_TARGET)
	$<

# TODO help target
#help:

# TODO install target, use install(1)
# need to split header files up first
#install: $(TARGET)
#	install $< $(PREFIX)/bin

clean:
	$(RM) $(TARGET) $(TEST_TARGET) $(OBJS) $(TEST_OBJS) $(DEPS) $(COVERAGE_DATA)

coverage_html: $(BUILD_DIR)/coverage_report/index.html
$(BUILD_DIR)/coverage_report/index.html: $(TEST_TARGET)
ifeq ($(COVERAGE), 0)
	$(error COVERAGE=1 option required)
endif
	$<
	@mkdir -p $(@D)
	gcovr --exclude test --exclude third_party --html-detail $@ -r .

-include $(DEPS)

.PHONY: all clean test run_test run_test run_benchmark coverage_html

