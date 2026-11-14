CC ?= clang
CFLAGS ?= -Wall -Wextra -Werror -O2 -fPIC
TMP ?= $(shell mktemp -d)

all: pam_faceauth.so

pam_faceauth.so: pam_faceauth.c pam_faceauth.h
	$(CC) $(CFLAGS) -bundle -o $@ pam_faceauth.c -lpam

test_pam: test_pam.c pam_faceauth.c pam_faceauth.h
	$(CC) $(CFLAGS) -o $@ test_pam.c pam_faceauth.c -lpam

test: test_pam
	./test_pam $(TMP)

clean:
	rm -f pam_faceauth.so test_pam

.PHONY: all test clean
