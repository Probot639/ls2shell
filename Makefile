CC      ?= gcc
CFLAGS  := -Wall -Wextra -O2 -std=c11
STRIP   := strip --strip-all

TARGET  := ls2shell

.PHONY: all clean

all: $(TARGET)

$(TARGET): ls2shell.c
	$(CC) $(CFLAGS) -o $@ $<
	$(STRIP) $@

clean:
	rm -f $(TARGET)
