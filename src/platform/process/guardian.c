#define _GNU_SOURCE
#include "posix_native.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#include <stdbool.h>
#include <sys/proc.h>
#include <time.h>
#elif defined(__linux__)
#include <dirent.h>
#include <limits.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#endif

static int report(uint8_t kind, uint8_t value) {
    const uint8_t message[] = {kind, value};
    ssize_t count;
    do {
        count = write(FOO_PROCESS_STATUS_FD, message, sizeof(message));
    } while (count == -1 && errno == EINTR);
    return count == sizeof(message) ? 0 : -1;
}

static uint8_t classify(int failure) {
    switch (failure) {
    case E2BIG: return FOO_PROCESS_LIMIT;
    case EINVAL:
    case ENOEXEC: return FOO_PROCESS_INVALID;
    case EACCES:
    case ENOENT:
    case ENOTDIR:
    case EPERM: return FOO_PROCESS_UNAVAILABLE;
    default: return FOO_PROCESS_IO;
    }
}

static int lease_open(pid_t owner, int timeout) {
    if (getppid() != owner) return 0;
    struct pollfd lease = { .fd = FOO_PROCESS_LEASE_FD, .events = POLLIN };
    int result = poll(&lease, 1, timeout);
    return result == 0 || (result == -1 && errno == EINTR);
}

static int read_exact(void *destination, size_t len) {
    char *cursor = destination;
    while (len > 0) {
        ssize_t n = read(FOO_PROCESS_LEASE_FD, cursor, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        cursor += n;
        len -= (size_t)n;
    }
    return 0;
}

static int spawn_command(pid_t *pid, char *argv[], char *envp[]) {
    const int stdio[] = {STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO};
    if (strchr(argv[0], '/') != NULL)
        return foo_process_spawn(pid, argv[0], stdio, 3, argv, envp);

    const char *path = "/usr/bin:/bin";
    for (char **env = envp; *env != NULL; ++env) {
        if (strncmp(*env, "PATH=", 5) == 0) {
            path = *env + 5;
            break;
        }
    }
    size_t command_len = strlen(argv[0]);
    char *candidate = malloc(strlen(path) + command_len + 2);
    if (candidate == NULL) return ENOMEM;
    int failure = ENOENT;
    for (;;) {
        size_t len = strcspn(path, ":");
        memcpy(candidate, path, len);
        if (len > 0) candidate[len] = '/';
        memcpy(candidate + len + (len > 0), argv[0], command_len + 1);
        int attempt = foo_process_spawn(pid, candidate, stdio, 3, argv, envp);
        if (attempt == EACCES) failure = EACCES;
        else if (attempt != ENOENT && attempt != ENOTDIR) {
            failure = attempt;
            break;
        }
        if (path[len] == '\0') break;
        path += len + 1;
    }
    free(candidate);
    return failure;
}

static int launch(pid_t *child, pid_t owner, const char *cwd, char *argv[]) {
    uint32_t size;
    if (read_exact(&size, sizeof(size)) == -1) return ECANCELED;
    long arg_max = sysconf(_SC_ARG_MAX);
    if (arg_max < 0 || size > (unsigned long)arg_max) return E2BIG;
    char *environment = malloc(size == 0 ? 1 : size);
    if (environment == NULL) return ENOMEM;
    int failure = ECANCELED;
    if (read_exact(environment, size) == 0) {
        size_t count = 0;
        for (size_t i = 0; i < size; ++i) count += environment[i] == '\0';
        char **envp = calloc(count + 1, sizeof(*envp));
        if (envp == NULL) failure = ENOMEM;
        else {
            size_t offset = 0;
            for (size_t i = 0; i < count; ++i) {
                envp[i] = environment + offset;
                offset += strlen(envp[i]) + 1;
            }
            if (offset != size) failure = EINVAL;
            else if (chdir(cwd) == -1) failure = errno;
            else if (lease_open(owner, 0)) failure = spawn_command(child, argv, envp);
            free(envp);
        }
    }
    free(environment);
    return failure;
}

#ifdef __APPLE__
static bool group_drained(pid_t group) {
    int capacity = proc_listpids(PROC_PGRP_ONLY, (uint32_t)group, NULL, 0);
    if (capacity <= 0) return false;
    pid_t *members = calloc(2, (size_t)capacity);
    if (members == NULL) return false;
    pid_t *confirmed = members + (size_t)capacity / sizeof(*members);

    errno = 0;
    int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)group, members, capacity);
    bool drained = errno == 0 && bytes >= 0 && bytes < capacity && (size_t)bytes % sizeof(*members) == 0;
    for (size_t i = 0; drained && i < (size_t)bytes / sizeof(*members); ++i) {
        struct proc_bsdshortinfo member;
        drained = proc_pidinfo(members[i], PROC_PIDT_SHORTBSDINFO, 1, &member, sizeof(member)) == sizeof(member) &&
            member.pbsi_pgid == (uint32_t)group && member.pbsi_status == SZOMB;
    }

    // A member can fork before it turns into a zombie. Check the group again after inspecting its members.
    if (drained) {
        errno = 0;
        drained = proc_listpids(PROC_PGRP_ONLY, (uint32_t)group, confirmed, capacity) == bytes &&
            errno == 0 && memcmp(members, confirmed, (size_t)bytes) == 0;
    }
    free(members);
    return drained;
}

static pid_t reap_if_exited(pid_t child, int *status) {
    pid_t waited;
    do {
        waited = waitpid(child, status, WNOHANG);
    } while (waited == -1 && errno == EINTR);
    return waited;
}

static int stop_and_reap(pid_t child, int *status) {
    struct timespec deadline;
    if (clock_gettime(CLOCK_MONOTONIC, &deadline) == -1) {
        (void)reap_if_exited(child, status);
        return -1;
    }
    deadline.tv_sec += 5;

    for (;;) {
        // The direct child may have changed groups. Its unreaped PID still reserves the original PGID.
        (void)kill(child, SIGKILL);
        // XNU snapshots the group before signalling and can report EPERM for a group of zombies.
        if (kill(-child, SIGKILL) == -1 && errno != ESRCH && errno != EPERM) break;
        if (group_drained(child)) {
            pid_t waited = reap_if_exited(child, status);
            if (waited != 0) return waited == child ? 0 : -1;
        }

        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now) == -1 || now.tv_sec > deadline.tv_sec ||
            (now.tv_sec == deadline.tv_sec && now.tv_nsec >= deadline.tv_nsec)) break;
        if (poll(NULL, 0, 10) == -1 && errno != EINTR) break;
    }
    (void)reap_if_exited(child, status);
    return -1;
}
#else
static int stop_and_reap(pid_t child, int *status) {
    // Keep the group leader's PID reserved until the group signal has been sent.
    if (kill(-child, SIGKILL) == -1 && errno != ESRCH) return -1;
    // The command can change its own group. Its PID remains ours to reap.
    if (kill(child, SIGKILL) == -1 && errno != ESRCH) return -1;
    pid_t waited;
    do {
        waited = waitpid(child, status, 0);
    } while (waited == -1 && errno == EINTR);
    if (waited == -1) return -1;
#ifdef __linux__
    // Adopted grandchildren can be reaped here without relying on PID 1.
    do {
        waited = waitpid(-child, NULL, 0);
    } while (waited > 0 || (waited == -1 && errno == EINTR));
    if (errno != ECHILD) return -1;
#endif
    return 0;
}
#endif

#ifdef __linux__
static int close_other_fds(void) {
#ifdef SYS_close_range
    if (syscall(SYS_close_range, FOO_PROCESS_STATUS_FD + 1, UINT_MAX, 0) == 0) return 0;
#endif
    DIR *fds = opendir("/proc/self/fd");
    if (fds == NULL) return -1;
    int failed = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(fds);
        if (entry == NULL) {
            failed = errno;
            break;
        }
        long fd = strtol(entry->d_name, NULL, 10);
        if (fd > FOO_PROCESS_STATUS_FD && fd <= INT_MAX && fd != dirfd(fds)) close((int)fd);
    }
    closedir(fds);
    return failed == 0 ? 0 : -1;
}
#endif

int main(int argc, char *argv[]) {
    if (argc < 4) return 1;
    pid_t owner = (pid_t)strtol(argv[1], NULL, 10);
    if (owner <= 0 || getppid() != owner) return 0;

    if (fcntl(FOO_PROCESS_LEASE_FD, F_SETFD, FD_CLOEXEC) == -1 ||
        fcntl(FOO_PROCESS_STATUS_FD, F_SETFD, FD_CLOEXEC) == -1 ||
        signal(SIGPIPE, SIG_IGN) == SIG_ERR) {
        report(FOO_PROCESS_FAILED, FOO_PROCESS_IO);
        return 1;
    }
#ifdef __linux__
    if (close_other_fds() == -1 || prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) == -1) {
        report(FOO_PROCESS_FAILED, FOO_PROCESS_IO);
        return 1;
    }
#endif
    pid_t child;
    int failure = launch(&child, owner, argv[2], argv + 3);
    if (failure == ECANCELED) return 0;
    if (failure != 0) {
        report(FOO_PROCESS_FAILED, classify(failure));
        return 0;
    }
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    int observation_failed = 0;
    if (report(FOO_PROCESS_READY, 0) == 0) {
        while (lease_open(owner, 10)) {
            siginfo_t exited = {0};
            if (waitid(P_PID, (id_t)child, &exited, WEXITED | WNOHANG | WNOWAIT) == -1) {
                if (errno == EINTR) continue;
                observation_failed = 1;
                break;
            }
            if (exited.si_pid != 0) break;
        }
    }
    int status;
    if (stop_and_reap(child, &status) == -1 || observation_failed) {
        report(FOO_PROCESS_FAILED, FOO_PROCESS_IO);
        return 1;
    }
    if (WIFEXITED(status)) report(FOO_PROCESS_EXITED, (uint8_t)WEXITSTATUS(status));
    else if (WIFSIGNALED(status)) report(FOO_PROCESS_SIGNALLED, (uint8_t)WTERMSIG(status));
    else {
        report(FOO_PROCESS_FAILED, FOO_PROCESS_IO);
        return 1;
    }
    return 0;
}
