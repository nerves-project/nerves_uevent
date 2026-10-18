# SPDX-FileCopyrightText: 2022 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

# Makefile for building port binaries
#
# Makefile targets:
#
# all/install   build and install the port binaries
# clean         clean build products and intermediates
#
# Variables to override:
#
# MIX_APP_PATH  path to the build directory
#
# CC            C compiler
# CROSSCOMPILE	crosscompiler prefix, if any
# CPPFLAGS	preprocessor flags for compiling all C files
# CFLAGS	compiler flags for compiling all C files
# ERL_CFLAGS	additional compiler flags for files using Erlang header files
# ERL_EI_INCLUDE_DIR include path to ei.h (Required for crosscompile)
# ERL_EI_LIBDIR path to libei.a (Required for crosscompile)
# LDFLAGS	linker flags for linking all binaries
# LDLIBS	additional libraries for linking all binaries
# ERL_LDFLAGS	additional linker flags for projects referencing Erlang libraries

PREFIX = $(MIX_APP_PATH)/priv
BUILD  = $(MIX_APP_PATH)/obj

# Check that we're on a supported build platform
ifeq ($(CROSSCOMPILE),)
    # Not crosscompiling, so check that we're on Linux.
    ifneq ($(shell uname -s),Linux)
        $(warning nerves_uevent only works on Linux, but crosscompilation)
        $(warning is supported by defining $$CROSSCOMPILE, $$ERL_EI_INCLUDE_DIR,)
        $(warning and $$ERL_EI_LIBDIR. See Makefile for details. If using Nerves,)
        $(warning this should be done automatically.)
        $(warning .)
        $(warning Skipping C compilation unless targets explicitly passed to make.)
	DEFAULT_TARGETS = $(PREFIX)
    endif
endif
DEFAULT_TARGETS ?= $(PREFIX) $(PREFIX)/uevent

# Set Erlang-specific compile and linker flags
ERL_CFLAGS ?= -I$(ERL_EI_INCLUDE_DIR)
ERL_LDFLAGS ?= -L$(ERL_EI_LIBDIR) -lei

CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -pedantic
CC ?= $(CROSSCOMPILE)-gcc

# Enable for debug messages
# CFLAGS += -DDEBUG

ifeq ($(origin CROSSCOMPILE), undefined)
SUDO_ASKPASS ?= /usr/bin/ssh-askpass
SUDO ?= true

# If not cross-compiling, then run sudo and suid the port binary
# so that it's possible to debug
update_perms = \
	echo "Not crosscompiling. To test locally, the port binary needs extra permissions.";\
	echo "Set SUDO=sudo to set permissions. The default is to skip this step.";\
	echo "SUDO_ASKPASS=$(SUDO_ASKPASS)";\
	echo "SUDO=$(SUDO)";\
	SUDO_ASKPASS=$(SUDO_ASKPASS) $(SUDO) -- sh -c 'chown root:root $(1); chmod +s $(1)'
else
# If cross-compiling, then permissions need to be set some build system-dependent way
update_perms =
endif

calling_from_make:
	mix compile

all: install

install: $(BUILD) $(DEFAULT_TARGETS)

$(BUILD)/%.o: c_src/%.c | $(BUILD)
	@echo " CC $(notdir $@)"
	$(CC) $(CPPFLAGS) $(ERL_CFLAGS) $(CFLAGS) -std=gnu99 -c -o $@ $<

$(PREFIX)/uevent: $(BUILD)/uevent.o | $(PREFIX)
	@echo " LD $(notdir $@)"
	$(CC) $(CFLAGS) $(LDFLAGS) $^ $(ERL_LDFLAGS) $(LDLIBS) -lmnl -o $@
	$(call update_perms, $@)

$(PREFIX) $(BUILD):
	mkdir -p $@

mix_clean:
	$(RM) $(PREFIX)/uevent $(BUILD)/*.o

clean:
	mix clean

.PHONY: all clean mix_clean calling_from_make install

# Don't echo commands unless the caller exports "V=1"
${V}.SILENT:
