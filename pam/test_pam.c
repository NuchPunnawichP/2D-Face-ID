/* Unit tests for pam_faceauth (R19, R23, R24, R27) with stub verifiers and a
 * test store owned by the current user. No root needed. */
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <fcntl.h>
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

static char dir[512], store[600], udir[700];

static void write_file(const char *path, const char *data, size_t len, mode_t mode) {
    unlink(path);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
    if (len) { ssize_t n = write(fd, data, len); (void)n; }
    close(fd);
    chmod(path, mode);
}

static void make_stub(const char *path, const char *body) {
    char script[2048];
    snprintf(script, sizeof script, "#!/bin/sh\n%s\n", body);
    write_file(path, script, strlen(script), 0755);
}

/* A valid store: <dir>/store/<uid>/{enrollment,config}.json */
static const char *ENROLL = "{\"e\":1}";
static const char *CONFIG = "{\"c\":2}";
static void reset_store(void) {
    char cmd[800];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", store);
    if (system(cmd) != 0) { /* ignore */ }
    mkdir(store, 0700); chmod(store, 0700);
    mkdir(udir, 0700); chmod(udir, 0700);
    char p[800];
    snprintf(p, sizeof p, "%s/enrollment.json", udir); write_file(p, ENROLL, strlen(ENROLL), 0600);
    snprintf(p, sizeof p, "%s/config.json", udir); write_file(p, CONFIG, strlen(CONFIG), 0600);
}

static int conv(int n, const struct pam_message **m, struct pam_response **r, void *d) {
    (void)n; (void)m; (void)r; (void)d; return PAM_CONV_ERR;
}

static int auth_with(const char *stub, int timeout) {
    struct passwd *pw = getpwuid(getuid());
    struct pam_conv c = { conv, NULL };
    pam_handle_t *pamh = NULL;
    if (pam_start("faceauth-test", pw->pw_name, &c, &pamh) != PAM_SUCCESS) return -999;
    char p[700], s[700], t[32];
    snprintf(p, sizeof p, "path=%s", stub);
    snprintf(s, sizeof s, "store=%s", store);
    snprintf(t, sizeof t, "timeout=%d", timeout);
    /* timeout <= 0: omit it, so the module's default (10 s) applies. */
    const char *argv[] = { p, s, t };
    int rc = pam_sm_authenticate(pamh, 0, timeout > 0 ? 3 : 2, argv);
    pam_end(pamh, rc);
    return rc;
}

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int exists(const char *p) { return access(p, F_OK) == 0; }

int main(int argc, char **argv) {
    snprintf(dir, sizeof dir, "%s", argc > 1 ? argv[1] : "/tmp");
    snprintf(store, sizeof store, "%s/store", dir);
    snprintf(udir, sizeof udir, "%s/%u", store, (unsigned)getuid());
    char s0[600], s1[600], s2[600], shang[600], swritable[600], sargs[600], secho[600], snoread[600];
    char got[700], ran[700], cmd[2000];
    snprintf(s0, sizeof s0, "%s/stub_exit0", dir);
    snprintf(s1, sizeof s1, "%s/stub_exit1", dir);
    snprintf(s2, sizeof s2, "%s/stub_exit2", dir);
    snprintf(shang, sizeof shang, "%s/stub_hang", dir);
    snprintf(swritable, sizeof swritable, "%s/stub_writable", dir);
    snprintf(sargs, sizeof sargs, "%s/stub_args", dir);
    snprintf(secho, sizeof secho, "%s/stub_echo", dir);
    snprintf(snoread, sizeof snoread, "%s/stub_noread", dir);
    snprintf(got, sizeof got, "%s/received.json", dir);
    snprintf(ran, sizeof ran, "%s/ran.marker", dir);

    make_stub(s0, "exit 0");
    make_stub(s1, "exit 1");
    make_stub(s2, "exit 2");
    make_stub(shang, "sleep 30; exit 0");
    make_stub(swritable, "exit 0");
    chmod(swritable, 0777);
    make_stub(sargs, "[ \"$1 $2 $3\" = 'verify --store-fd 3' ] && [ -n \"$HOME\" ] && [ -z \"$SUDO_ASKPASS\" ] && exit 0; exit 1");
    snprintf(cmd, sizeof cmd, "touch '%s'; cat <&3 > '%s'; exit 0", ran, got);
    make_stub(secho, cmd);
    snprintf(cmd, sizeof cmd, "touch '%s'; sleep 30", ran);
    make_stub(snoread, cmd);
    reset_store();

    /* R19: exit codes. */
    CHECK(auth_with(s0, 10) == PAM_SUCCESS, "exit 0 -> PAM_SUCCESS");
    CHECK(auth_with(s1, 10) == PAM_AUTH_ERR, "exit 1 -> PAM_AUTH_ERR");
    CHECK(auth_with(s2, 10) == PAM_AUTH_ERR, "exit 2 -> PAM_AUTH_ERR");
    CHECK(auth_with(sargs, 10) == PAM_SUCCESS, "called as 'verify --store-fd 3' with a minimal env");

    /* R23: the verifier receives exactly the root-store bundle on fd 3. */
    unlink(got);
    CHECK(auth_with(secho, 10) == PAM_SUCCESS, "echo stub succeeds");
    {
        char expect[256], buf[256] = {0};
        snprintf(expect, sizeof expect, "{\"enrollment\":%s,\"config\":%s}", ENROLL, CONFIG);
        FILE *f = fopen(got, "r");
        size_t n = f ? fread(buf, 1, sizeof buf - 1, f) : 0;
        if (f) fclose(f);
        CHECK(n == strlen(expect) && memcmp(buf, expect, n) == 0, "fd 3 carries exactly {enrollment, config} from the root store");
    }

    /* R19: timeouts, including a verifier that never reads fd 3 (non-blocking write). */
    double a = now();
    int rc = auth_with(shang, 2);
    double el = now() - a;
    char msg[160];
    CHECK(rc == PAM_AUTH_ERR, "hanging verifier -> PAM_AUTH_ERR");
    snprintf(msg, sizeof msg, "hanging verifier killed after timeout (%.2f s, limit 2 s)", el);
    CHECK(el >= 2.0 && el < 3.0, msg);
    a = now(); rc = auth_with(shang, 0); el = now() - a;
    snprintf(msg, sizeof msg, "default timeout kills a hanging verifier at 10 s (%.2f s)", el);
    CHECK(rc == PAM_AUTH_ERR && el >= 10.0 && el < 11.0, msg);

    {   /* 60 KB enrollment, verifier never reads: must not block past the timeout. */
        char *big = malloc(60000);
        memset(big, ' ', 60000); big[0] = '{'; big[59999] = '}';
        char p[800];
        snprintf(p, sizeof p, "%s/enrollment.json", udir);
        write_file(p, big, 60000, 0600);
        free(big);
        a = now(); rc = auth_with(snoread, 2); el = now() - a;
        snprintf(msg, sizeof msg, "60 KB store, verifier never reads: no hang, killed at 2 s (%.2f s)", el);
        CHECK(rc == PAM_AUTH_ERR && el < 3.0, msg);
        reset_store();
    }

    /* Binary checks (rev 3). */
    CHECK(auth_with(swritable, 10) == PAM_AUTH_ERR, "world-writable binary refused");
    CHECK(auth_with("/nonexistent/faceauth", 10) == PAM_AUTH_ERR, "missing binary -> PAM_AUTH_ERR");
    CHECK(auth_with("relative/path", 10) == PAM_AUTH_ERR, "relative path refused");
    char slink[600];
    snprintf(slink, sizeof slink, "%s/stub_symlink", dir);
    unlink(slink);
    if (symlink("/usr/bin/true", slink) != 0) { /* ignore */ }
    CHECK(auth_with(slink, 10) == PAM_AUTH_ERR, "symlinked binary refused");
    char dotdot[1300];
    snprintf(dotdot, sizeof dotdot, "%s/../%s/stub_exit0", dir, strrchr(dir, '/') + 1);
    CHECK(auth_with(dotdot, 10) == PAM_AUTH_ERR, "path containing /../ refused");

    /* R24 / R27: an invalid or missing store never starts the verifier. */
    struct { const char *name; const char *shell; } bad[] = {
        { "no store for this user", "rm -rf '%s'" },
        { "user dir mode 0755", "chmod 755 '%s'" },
        { "enrollment.json mode 0644", "chmod 644 '%s/enrollment.json'" },
        { "config.json missing", "rm '%s/config.json'" },
        { "enrollment.json is a symlink", "mv '%1$s/enrollment.json' '%1$s/real' && ln -s '%1$s/real' '%1$s/enrollment.json'" },
        { "enrollment.json over 64 KiB", "head -c 70000 /dev/zero > '%s/enrollment.json'" },
        { "empty config.json", ": > '%s/config.json'" },
    };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        reset_store();
        char sh[1600];
        snprintf(sh, sizeof sh, bad[i].shell, udir, udir, udir, udir);
        if (system(sh) != 0) { /* some cases are expected to be no-ops */ }
        unlink(ran);
        rc = auth_with(secho, 10);
        snprintf(msg, sizeof msg, "%s -> PAM_AUTH_ERR, verifier not started", bad[i].name);
        CHECK(rc == PAM_AUTH_ERR && !exists(ran), msg);
    }
    reset_store();
    chmod(store, 0755);
    unlink(ran);
    CHECK(auth_with(secho, 10) == PAM_AUTH_ERR && !exists(ran), "store root mode 0755 -> PAM_AUTH_ERR, verifier not started");
    reset_store();

    /* Status mapping. */
    CHECK(faceauth_status_to_pam(0) == PAM_SUCCESS, "status 0 maps to success");
    CHECK(faceauth_status_to_pam(1 << 8) == PAM_AUTH_ERR, "status exit 1 maps to error");
    CHECK(faceauth_status_to_pam(9) == PAM_AUTH_ERR, "killed by signal maps to error");

    CHECK(pam_sm_setcred(NULL, 0, 0, NULL) == PAM_SUCCESS, "setcred is a no-op");
    printf("%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
