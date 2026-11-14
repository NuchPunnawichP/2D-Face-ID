/*
 * pam_faceauth: a PAM auth module that runs `faceauth verify` as the
 * invoking user and succeeds only if it exits 0 (SPEC R19).
 *
 * Use it ONLY as `auth sufficient` in /etc/pam.d/sudo_local, so that any
 * failure falls through to the normal password prompt.
 *
 * Module options:
 *   path=/usr/local/libexec/faceauth   the faceauth binary (default shown)
 *   timeout=10                         seconds before the child is killed
 *
 * Safety rules:
 *   - When running as root (normal use under sudo) the binary must be owned by
 *     root and not writable by group or others; otherwise the module refuses.
 *   - The child drops to the target user's uid/gid before exec, with a
 *     minimal environment.
 *   - Every error path returns PAM_AUTH_ERR, never PAM_SUCCESS.
 */
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#include <security/pam_appl.h>
#include <security/pam_modules.h>

#include "pam_faceauth.h"

#define DEFAULT_PATH "/usr/local/libexec/faceauth"
#define DEFAULT_TIMEOUT 10

/* Owner/mode rule for the binary and each directory above it. */
static int trusted_owner_and_mode(const struct stat *st) {
    if (st->st_mode & (S_IWGRP | S_IWOTH)) return 0;
    if (geteuid() == 0) return st->st_uid == 0;
    /* Unprivileged (tests): allow root or ourselves. */
    return st->st_uid == 0 || st->st_uid == geteuid();
}

/*
 * Returns 0 if `path` is safe to execute for the current privilege level:
 * an absolute path, not a symlink, a regular executable file, and it and
 * every parent directory owned by root (or, unprivileged, by us) and not
 * writable by group or others.
 */
int faceauth_check_binary(const char *path) {
    struct stat st;
    if (path == NULL || path[0] != '/' || strstr(path, "/../") != NULL || strlen(path) >= 1024) return -1;
    if (lstat(path, &st) != 0) return -1;
    if (S_ISLNK(st.st_mode)) return -1;
    char dir[1024];
    strncpy(dir, path, sizeof dir - 1);
    dir[sizeof dir - 1] = '\0';
    for (char *slash = strrchr(dir, '/'); slash != NULL; slash = strrchr(dir, '/')) {
        if (slash == dir) { dir[1] = '\0'; } else { *slash = '\0'; }
        struct stat ds;
        if (lstat(dir, &ds) != 0) return -1;
        /* /tmp-style sticky world-writable dirs are allowed only unprivileged (tests). */
        int sticky_ok = geteuid() != 0 && (ds.st_mode & S_ISVTX);
        if (!S_ISDIR(ds.st_mode) && !S_ISLNK(ds.st_mode)) return -1;
        if (!sticky_ok && geteuid() == 0 && (ds.st_uid != 0 || (ds.st_mode & (S_IWGRP | S_IWOTH)))) return -1;
        if (strcmp(dir, "/") == 0) break;
    }
    if (!S_ISREG(st.st_mode) || !(st.st_mode & S_IXUSR)) return -1;
    if (!trusted_owner_and_mode(&st)) return -1;
    return 0;
}

/* Maps the verifier's wait status to a PAM result: only a clean exit 0 succeeds. */
int faceauth_status_to_pam(int status) {
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return PAM_SUCCESS;
    return PAM_AUTH_ERR;
}

/*
 * Runs `path verify` as `pw` (when we are root) and waits up to timeout_s.
 * Returns the wait status, or -1 on error / timeout (child killed).
 */
int faceauth_run(const char *path, const struct passwd *pw, int timeout_s) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        /* Child. Drop privileges first if we have them. */
        if (geteuid() == 0) {
            if (initgroups(pw->pw_name, (int)pw->pw_gid) != 0) _exit(126);
            if (setgid(pw->pw_gid) != 0) _exit(126);
            if (setuid(pw->pw_uid) != 0) _exit(126);
            if (setuid(0) == 0) _exit(126); /* must not be able to regain root */
        }
        /* stdin from /dev/null: the verifier must never read a password. */
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, STDIN_FILENO); close(devnull); }
        char home[1024], user[256], logname[256];
        snprintf(home, sizeof home, "HOME=%s", pw->pw_dir);
        snprintf(user, sizeof user, "USER=%s", pw->pw_name);
        snprintf(logname, sizeof logname, "LOGNAME=%s", pw->pw_name);
        char *envp[] = { home, user, logname, "PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL };
        char *argv[] = { (char *)path, "verify", NULL };
        if (chdir(pw->pw_dir) != 0) { /* not fatal */ }
        execve(path, argv, envp);
        _exit(127);
    }

    /* Parent: poll for exit with a deadline. */
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        int status = 0;
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) return status;
        if (r < 0 && errno != EINTR) return -1;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (now.tv_sec - start.tv_sec) + (now.tv_nsec - start.tv_nsec) / 1e9;
        if (elapsed >= timeout_s) {
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
            return -1;
        }
        struct timespec nap = { 0, 20 * 1000 * 1000 };
        nanosleep(&nap, NULL);
    }
}

static void parse_args(int argc, const char **argv, const char **path, int *timeout_s) {
    *path = DEFAULT_PATH;
    *timeout_s = DEFAULT_TIMEOUT;
    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "path=", 5) == 0) *path = argv[i] + 5;
        else if (strncmp(argv[i], "timeout=", 8) == 0) {
            int t = atoi(argv[i] + 8);
            if (t > 0 && t <= 60) *timeout_s = t;
        }
    }
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)flags;
    const char *path;
    int timeout_s;
    parse_args(argc, argv, &path, &timeout_s);

    const char *user = NULL;
    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL || user[0] == '\0')
        return PAM_AUTH_ERR;

    struct passwd pwbuf, *pw = NULL;
    char buf[4096];
    if (getpwnam_r(user, &pwbuf, buf, sizeof buf, &pw) != 0 || pw == NULL) return PAM_AUTH_ERR;

    if (faceauth_check_binary(path) != 0) {
        syslog(LOG_AUTH | LOG_WARNING, "pam_faceauth: refusing unsafe or missing binary %s", path);
        return PAM_AUTH_ERR;
    }

    int status = faceauth_run(path, pw, timeout_s);
    if (status == -1) {
        syslog(LOG_AUTH | LOG_NOTICE, "pam_faceauth: verifier failed or timed out for %s", user);
        return PAM_AUTH_ERR;
    }
    int rc = faceauth_status_to_pam(status);
    syslog(LOG_AUTH | LOG_NOTICE, "pam_faceauth: %s for %s",
           rc == PAM_SUCCESS ? "face matched" : "no match", user);
    return rc;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}
