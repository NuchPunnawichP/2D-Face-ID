#ifndef PAM_FACEAUTH_H
#define PAM_FACEAUTH_H
#include <pwd.h>
int faceauth_check_binary(const char *path);
int faceauth_status_to_pam(int status);
int faceauth_run(const char *path, const struct passwd *pw, int timeout_s);
#endif
