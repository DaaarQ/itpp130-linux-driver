CC ?= cc
CFLAGS ?= -O2
WARNINGS = -Wall -Wextra -Wpedantic -Wconversion -Wshadow -Wformat=2 \
	-Werror -Wno-deprecated-declarations
LDLIBS = -lcups -lcupsimage
FILTER = rastertolabel-itpp130

.PHONY: all test check analyze sanitize clean

all: $(FILTER)

$(FILTER): rastertolabel-itpp130.c
	$(CC) $(CFLAGS) $(WARNINGS) -o $@ $< $(LDLIBS)

test: $(FILTER)
	tests/run-tests.sh ./$(FILTER)

check: test
	cupstestppd -I filters -q ITPP130-Label-printer.ppd
	bash -n gstoraster2tspl tests/run-tests.sh
	sh -n install.sh packaging/build-all.sh

analyze:
	clang --analyze -Wno-deprecated-declarations -o /dev/null \
		rastertolabel-itpp130.c

sanitize:
	$(CC) -O1 -g $(WARNINGS) -fsanitize=address,undefined \
		-fno-omit-frame-pointer -o $(FILTER)-sanitize \
		rastertolabel-itpp130.c $(LDLIBS)
	ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
	UBSAN_OPTIONS=halt_on_error=1 \
		tests/run-tests.sh ./$(FILTER)-sanitize

clean:
	rm -f $(FILTER) $(FILTER)-sanitize tests/make_fixtures
	rm -rf $(FILTER)-sanitize.dSYM tests/fixtures
	rm -f $(FILTER).plist
