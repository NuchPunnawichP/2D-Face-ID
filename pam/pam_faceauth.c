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
 *   store=/var/db/faceauth             the root-owned store (SPEC rev 4)
 *
 * Safety rules:
 *   - When running as root (normal use under sudo) the binary must be owned by
 *     root and not writable by group or others; otherwise the module refuses.
 *   - The child drops to the target user's uid/gid before exec, with a
 *     minimal environment.
 *   - The user's root-owned store (<store>/<uid>/, 0700/0600 root:wheel) is
 *     read here and written to the child's fd 3; without a valid store the
 *     verifier is not started (PAM_AUTH_ERR → password prompt).
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
#define DEFAULT_STORE "/var/db/faceauth"

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

/* Owner/mode rule for the root store: exact mode, and root:wheel when we are root. */
static int store_entry_ok(const struct stat *st, mode_t want_mode) {
    if ((st->st_mode & 07777) != want_mode) return 0;
    if (geteuid() == 0) return st->st_uid == 0 && st->st_gid == 0;
    return st->st_uid == 0 || st->st_uid == geteuid(); /* unprivileged tests */
}

/* Reads a whole store file (no symlinks, regular, 0600, trusted owner) into buf. */
static long read_store_file(const char *path, char *buf, size_t cap) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || !store_entry_ok(&st, 0600) ||
        st.st_size <= 0 || (size_t)st.st_size > cap) {
        close(fd);
        return -1;
    }
    size_t got = 0;
    while (got < (size_t)st.st_size) {
        ssize_t n = read(fd, buf + got, (size_t)st.st_size - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return -1; }
        got += (size_t)n;
    }
    close(fd);
    return (long)got;
}

/*
 * Loads <root>/<uid>/{enrollment,config}.json into `out` as
 * {"enrollment":...,"config":...}. Returns the length, or -1 if the store is
 * missing or invalid (wrong owner/mode, symlink, or over FACEAUTH_STORE_MAX).
 * SPEC rev 4, R24 and R27.
 */
long faceauth_load_store(const char *root, uid_t uid, char *out, size_t cap) {
    char dir[1024], ep[1100], cp[1100];
    struct stat st;
    if (root == NULL || root[0] != '/' || strstr(root, "/../") != NULL) return -1;
    if (lstat(root, &st) != 0 || !S_ISDIR(st.st_mode) || !store_entry_ok(&st, 0700)) return -1;
    snprintf(dir, sizeof dir, "%s/%u", root, (unsigned)uid);
    if (lstat(dir, &st) != 0 || !S_ISDIR(st.st_mode) || !store_entry_ok(&st, 0700)) return -1;
    snprintf(ep, sizeof ep, "%s/enrollment.json", dir);
    snprintf(cp, sizeof cp, "%s/config.json", dir);

    static const char pre[] = "{\"enrollment\":", mid[] = ",\"config\":", post[] = "}";
    size_t limit = cap < FACEAUTH_STORE_MAX ? cap : FACEAUTH_STORE_MAX;
    size_t fixed = sizeof pre - 1 + sizeof mid - 1 + sizeof post - 1;
    if (limit <= fixed) return -1;
    size_t pos = 0;
    memcpy(out + pos, pre, sizeof pre - 1); pos += sizeof pre - 1;
    long n = read_store_file(ep, out + pos, limit - fixed - pos + (sizeof pre - 1));
    if (n < 0) return -1;
    pos += (size_t)n;
    if (pos + sizeof mid - 1 >= limit) return -1;
    memcpy(out + pos, mid, sizeof mid - 1); pos += sizeof mid - 1;
    long m = read_store_file(cp, out + pos, limit - pos - (sizeof post - 1));
    if (m < 0) return -1;
    pos += (size_t)m;
    if (pos + sizeof post - 1 > limit) return -1;
    memcpy(out + pos, post, sizeof post - 1); pos += sizeof post - 1;
    return (long)pos;
}

/*
 * Runs `path verify --store-fd 3` as `pw` (when we are root), writes `data` to
 * the child's fd 3 without blocking, and waits up to timeout_s.
 * Returns the wait status, or -1 on error / timeout (child killed).
 */
int faceauth_run(const char *path, const struct passwd *pw, int timeout_s, const char *data, size_t len) {
    int fds[2];
    if (pipe(fds) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(fds[0]); close(fds[1]); return -1; }
    if (pid == 0) {
        /* Child. Drop privileges first if we have them. */
        if (geteuid() == 0) {
            if (initgroups(pw->pw_name, (int)pw->pw_gid) != 0) _exit(126);
            if (setgid(pw->pw_gid) != 0) _exit(126);
            if (setuid(pw->pw_uid) != 0) _exit(126);
            if (setuid(0) == 0) _exit(126); /* must not be able to regain root */
        }
        close(fds[1]);
        if (fds[0] != 3) {
            if (dup2(fds[0], 3) != 3) _exit(126);
            close(fds[0]);
        }
        /* stdin from /dev/null: the verifier must never read a password. */
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, STDIN_FILENO); close(devnull); }
        /* Close every other descriptor above 3. */
        int maxfd = getdtablesize();
        for (int fd = 4; fd < maxfd; fd++) close(fd);
        char home[1024], user[256], logname[256];
        snprintf(home, sizeof home, "HOME=%s", pw->pw_dir);
        snprintf(user, sizeof user, "USER=%s", pw->pw_name);
        snprintf(logname, sizeof logname, "LOGNAME=%s", pw->pw_name);
        char *envp[] = { home, user, logname, "PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL };
        char *argv[] = { (char *)path, "verify", "--store-fd", "3", NULL };
        if (chdir(pw->pw_dir) != 0) { /* not fatal */ }
        execve(path, argv, envp);
        _exit(127);
    }

    /* Parent. Non-blocking writes, and no SIGPIPE if the child stops reading. */
    close(fds[0]);
    int w = fds[1];
    fcntl(w, F_SETNOSIGPIPE, 1);
    fcntl(w, F_SETFL, fcntl(w, F_GETFL) | O_NONBLOCK);
    size_t sent = 0;

    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        if (w >= 0) {
            ssize_t n = len > sent ? write(w, data + sent, len - sent) : 0;
            if (n > 0) sent += (size_t)n;
            if (sent >= len || (n < 0 && errno != EAGAIN && errno != EINTR)) { close(w); w = -1; }
        }
        int status = 0;
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) { if (w >= 0) close(w); return status; }
        if (r < 0 && errno != EINTR) { if (w >= 0) close(w); return -1; }
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (now.tv_sec - start.tv_sec) + (now.tv_nsec - start.tv_nsec) / 1e9;
        if (elapsed >= timeout_s) {
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
            if (w >= 0) close(w);
            return -1;
        }
        struct timespec nap = { 0, 20 * 1000 * 1000 };
        nanosleep(&nap, NULL);
    }
}

static void parse_args(int argc, const char **argv, const char **path, int *timeout_s, const char **store) {
    *path = DEFAULT_PATH;
    *timeout_s = DEFAULT_TIMEOUT;
    *store = DEFAULT_STORE;
    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "path=", 5) == 0) *path = argv[i] + 5;
        else if (strncmp(argv[i], "store=", 6) == 0) *store = argv[i] + 6;
        else if (strncmp(argv[i], "timeout=", 8) == 0) {
            int t = atoi(argv[i] + 8);
            if (t > 0 && t <= 60) *timeout_s = t;
        }
    }
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)flags;
    const char *path, *store;
    int timeout_s;
    parse_args(argc, argv, &path, &timeout_s, &store);

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

    /* The root-owned store for this user; without it, go straight to the password (Q20). */
    char *data = malloc(FACEAUTH_STORE_MAX);
    if (data == NULL) return PAM_AUTH_ERR;
    long len = faceauth_load_store(store, pw->pw_uid, data, FACEAUTH_STORE_MAX);
    if (len < 0) {
        free(data);
        syslog(LOG_AUTH | LOG_NOTICE, "pam_faceauth: no valid sudo enrollment for %s", user);
        return PAM_AUTH_ERR;
    }

    int status = faceauth_run(path, pw, timeout_s, data, (size_t)len);
    memset(data, 0, (size_t)len);
    free(data);
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
