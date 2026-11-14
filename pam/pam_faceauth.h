#ifndef PAM_FACEAUTH_H
#define PAM_FACEAUTH_H
#include <pwd.h>
#include <stddef.h>
#include <sys/types.h>

/* Largest store bundle handed to the verifier (SPEC rev 4, Q24). */
#define FACEAUTH_STORE_MAX (64 * 1024)

int faceauth_check_binary(const char *path);
int faceauth_status_to_pam(int status);
int faceauth_tty_ok(const char *tty);
long faceauth_load_store(const char *root, uid_t uid, char *out, size_t cap);
int faceauth_run(const char *path, const struct passwd *pw, int timeout_s, const char *data, size_t len);
#endif
