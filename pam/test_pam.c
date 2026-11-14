/* Unit tests for pam_faceauth (R19) with stub verifiers. No root needed. */
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "pam_faceauth.h"

static int failures = 0;
#define CHECK(cond, msg) do { if (cond) printf("ok   %s\n", msg); else { printf("FAIL %s\n", msg); failures++; } } while (0)

static void make_stub(const char *path, const char *body) {
    FILE *f = fopen(path, "w");
    fprintf(f, "#!/bin/sh\n%s\n", body);
    fclose(f);
    chmod(path, 0755);
}

static int conv(int n, const struct pam_message **m, struct pam_response **r, void *d) {
    (void)n; (void)m; (void)r; (void)d; return PAM_CONV_ERR;
}

static int auth_with(const char *stub, int timeout) {
    struct passwd *pw = getpwuid(getuid());
    struct pam_conv c = { conv, NULL };
    pam_handle_t *pamh = NULL;
    if (pam_start("faceauth-test", pw->pw_name, &c, &pamh) != PAM_SUCCESS) return -999;
    char p[600], t[32];
    snprintf(p, sizeof p, "path=%s", stub);
    snprintf(t, sizeof t, "timeout=%d", timeout);
    const char *argv[] = { p, t };
    /* timeout <= 0: pass only path=, so the module's default (10 s) applies. */
    int rc = pam_sm_authenticate(pamh, 0, timeout > 0 ? 2 : 1, argv);
    pam_end(pamh, rc);
    return rc;
}

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "/tmp";
    char s0[512], s1[512], s2[512], shang[512], swritable[512], sargs[512];
    snprintf(s0, sizeof s0, "%s/stub_exit0", dir);
    snprintf(s1, sizeof s1, "%s/stub_exit1", dir);
    snprintf(s2, sizeof s2, "%s/stub_exit2", dir);
    snprintf(shang, sizeof shang, "%s/stub_hang", dir);
    snprintf(swritable, sizeof swritable, "%s/stub_writable", dir);
    snprintf(sargs, sizeof sargs, "%s/stub_args", dir);
    make_stub(s0, "exit 0");
    make_stub(s1, "exit 1");
    make_stub(s2, "exit 2");
    make_stub(shang, "sleep 30; exit 0");
    make_stub(swritable, "exit 0");
    chmod(swritable, 0777);
    make_stub(sargs, "[ \"$1\" = verify ] && [ -n \"$HOME\" ] && [ -z \"$SUDO_ASKPASS\" ] && exit 0; exit 1");

    CHECK(auth_with(s0, 10) == PAM_SUCCESS, "exit 0 -> PAM_SUCCESS");
    CHECK(auth_with(s1, 10) == PAM_AUTH_ERR, "exit 1 -> PAM_AUTH_ERR");
    CHECK(auth_with(s2, 10) == PAM_AUTH_ERR, "exit 2 -> PAM_AUTH_ERR");
    CHECK(auth_with(sargs, 10) == PAM_SUCCESS, "called with 'verify' and a minimal env");

    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    int rc = auth_with(shang, 2);
    clock_gettime(CLOCK_MONOTONIC, &b);
    double el = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
    CHECK(rc == PAM_AUTH_ERR, "hanging verifier -> PAM_AUTH_ERR");
    char msg[128];
    snprintf(msg, sizeof msg, "hanging verifier killed after timeout (%.2f s, limit 2 s)", el);
    CHECK(el >= 2.0 && el < 3.0, msg);

    clock_gettime(CLOCK_MONOTONIC, &a);
    rc = auth_with(shang, 0);
    clock_gettime(CLOCK_MONOTONIC, &b);
    el = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
    snprintf(msg, sizeof msg, "default timeout kills a hanging verifier at 10 s (%.2f s)", el);
    CHECK(rc == PAM_AUTH_ERR && el >= 10.0 && el < 11.0, msg);

    CHECK(auth_with(swritable, 10) == PAM_AUTH_ERR, "world-writable binary refused");
    CHECK(auth_with("/nonexistent/faceauth", 10) == PAM_AUTH_ERR, "missing binary -> PAM_AUTH_ERR");
    CHECK(auth_with("relative/path", 10) == PAM_AUTH_ERR, "relative path refused");
    char slink[512];
    snprintf(slink, sizeof slink, "%s/stub_symlink", dir);
    unlink(slink);
    symlink("/usr/bin/true", slink);
    CHECK(auth_with(slink, 10) == PAM_AUTH_ERR, "symlinked binary refused");
    char dotdot[600];
    snprintf(dotdot, sizeof dotdot, "%s/../%s/stub_exit0", dir, strrchr(dir, '/') + 1);
    CHECK(auth_with(dotdot, 10) == PAM_AUTH_ERR, "path containing /../ refused");

    /* Signals and odd statuses never succeed. */
    CHECK(faceauth_status_to_pam(0) == PAM_SUCCESS, "status 0 maps to success");
    CHECK(faceauth_status_to_pam(1 << 8) == PAM_AUTH_ERR, "status exit 1 maps to error");
    CHECK(faceauth_status_to_pam(9) == PAM_AUTH_ERR, "killed by signal maps to error");

    CHECK(pam_sm_setcred(NULL, 0, 0, NULL) == PAM_SUCCESS, "setcred is a no-op");
    printf("%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
