# pumaterm -- a GL-accelerated terminal for Mac OS X 10.5 (PowerPC).
# Built natively on the boards with Apple's gcc-4.2 (Objective-C + 10.5 SDK).
#   make            -> build/PumaTerm.app
#   make install    -> /Applications/PumaTerm.app
#   make run        -> open it (needs the console user's WindowServer)
CC      ?= /usr/bin/gcc-4.2
ARCH    ?= -arch ppc
CFLAGS  += $(ARCH) -O2 -g -Wall -mmacosx-version-min=10.5 \
           -Ivendor/libvterm/include -Ivendor/libvterm/src
VTERM_SRC := $(wildcard vendor/libvterm/src/*.c)
APP_SRC   := src/main.m src/Prefs.m src/PrefsWindow.m src/TermWindow.m src/TermView.m src/GlyphAtlas.m src/Pty.c
OBJ := $(patsubst %.c,build/obj/%.o,$(VTERM_SRC)) \
       $(patsubst %.m,build/obj/%.o,$(filter %.m,$(APP_SRC))) \
       $(patsubst %.c,build/obj/%.o,$(filter %.c,$(APP_SRC)))
FRAMEWORKS := -framework Cocoa -framework OpenGL -framework ApplicationServices
APP := build/PumaTerm.app

all: $(APP)/Contents/MacOS/pumaterm $(APP)/Contents/Info.plist

build/obj/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu99 -c $< -o $@

build/obj/%.o: %.m
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu99 -c $< -o $@

$(APP)/Contents/MacOS/pumaterm: $(OBJ)
	@mkdir -p $(dir $@)
	$(CC) $(ARCH) -mmacosx-version-min=10.5 -o $@ $(OBJ) $(FRAMEWORKS) -lutil

$(APP)/Contents/Info.plist: Info.plist
	@mkdir -p $(dir $@)
	cp $< $@

run: all
	open $(APP)

install: all
	rm -rf /Applications/PumaTerm.app
	cp -R $(APP) /Applications/

clean:
	rm -rf build

.PHONY: all run install clean
