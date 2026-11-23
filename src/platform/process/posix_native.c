#define _GNU_SOURCE
#include "posix_native.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifdef __APPLE__
static int make_pipe(const char *path, int fds[2]) {
    if (mkfifo(path, S_IRUSR | S_IWUSR) == -1) return -1;
    int flags = O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW;
    fds[0] = open(path, O_RDONLY | flags);
    if (fds[0] != -1) fds[1] = open(path, O_WRONLY | flags);
    int saved = errno;
    if (unlink(path) == -1) return -1;
    errno = saved;
    return fds[1] == -1 ? -1 : 0;
}
#endif

int foo_process_pipes(int (*pipes)[2]) {
    for (size_t i = 0; i < FOO_PROCESS_PIPE_COUNT; ++i) {
        pipes[i][0] = pipes[i][1] = -1;
    }
#ifdef __APPLE__
    // Older Darwin versions lack pipe2. Open both ends with O_CLOEXEC before
    // unlinking the FIFO so an unrelated concurrent exec cannot inherit either end.
    char dir[] = "/tmp/foo-process.XXXXXX";
    if (mkdtemp(dir) == NULL) return errno;
    char path[sizeof(dir) + 2];
    memcpy(path, dir, sizeof(dir) - 1);
    path[sizeof(dir) - 1] = '/';
    path[sizeof(dir) + 1] = '\0';
#endif
    int failure = 0;
    for (size_t i = 0; i < FOO_PROCESS_PIPE_COUNT; ++i) {
#ifdef __APPLE__
        path[sizeof(dir)] = (char)('0' + i);
        if (make_pipe(path, pipes[i]) == -1) {
#else
        if (pipe2(pipes[i], O_CLOEXEC | O_NONBLOCK) == -1) {
#endif
            failure = errno;
            break;
        }
    }
#ifdef __APPLE__
    if (rmdir(dir) == -1 && failure == 0) failure = errno;
    for (size_t i = 0; i < FOO_PROCESS_PIPE_COUNT && failure == 0; ++i) {
        if ((i == FOO_PROCESS_STDIN || i == FOO_PROCESS_LEASE) && fcntl(pipes[i][1], F_SETNOSIGPIPE, 1) == -1)
            failure = errno;
    }
#endif
    // Keep the command's stdio and the guardian's lease reader blocking. All
    // endpoints used by the owner remain nonblocking for cancellation checks.
    for (size_t i = 0; i < FOO_PROCESS_PIPE_COUNT && failure == 0; ++i) {
        int child_fd = pipes[i][i == FOO_PROCESS_STDIN || i == FOO_PROCESS_LEASE ? 0 : 1];
        if (fcntl(child_fd, F_SETFL, 0) == -1) failure = errno;
    }
    if (failure != 0) {
        for (size_t i = 0; i < FOO_PROCESS_PIPE_COUNT; ++i) {
            if (pipes[i][0] != -1) close(pipes[i][0]);
            if (pipes[i][1] != -1) close(pipes[i][1]);
        }
    }
    return failure;
}

int foo_process_spawn(pid_t *pid, const char *path, const int *fds, size_t fd_count,
                      char *const argv[], char *const envp[]) {
    posix_spawn_file_actions_t actions;
    int failure = posix_spawn_file_actions_init(&actions);
    if (failure != 0) return failure;
    int copies[FOO_PROCESS_PIPE_COUNT];
    for (size_t i = 0; i < fd_count; ++i) copies[i] = -1;
    for (size_t i = 0; i < fd_count && failure == 0; ++i) {
        // Stage sources above all targets. The host may have closed standard FDs.
        copies[i] = fcntl(fds[i], F_DUPFD_CLOEXEC, FOO_PROCESS_PIPE_COUNT);
        failure = copies[i] == -1 ? errno :
            posix_spawn_file_actions_adddup2(&actions, copies[i], (int)i);
    }
    posix_spawnattr_t attr;
    if (failure == 0) {
        failure = posix_spawnattr_init(&attr);
        if (failure == 0) {
            sigset_t empty, defaults;
            sigemptyset(&empty);
            sigfillset(&defaults);
            sigdelset(&defaults, SIGKILL);
            sigdelset(&defaults, SIGSTOP);
            short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
#ifdef __APPLE__
            flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
            failure = posix_spawnattr_setflags(&attr, flags);
            if (failure == 0) failure = posix_spawnattr_setpgroup(&attr, 0);
            if (failure == 0) failure = posix_spawnattr_setsigmask(&attr, &empty);
            if (failure == 0) failure = posix_spawnattr_setsigdefault(&attr, &defaults);
            if (failure == 0) failure = posix_spawn(pid, path, &actions, &attr, argv, envp);
            posix_spawnattr_destroy(&attr);
        }
    }
    for (size_t i = 0; i < fd_count; ++i) {
        if (copies[i] != -1) close(copies[i]);
    }
    posix_spawn_file_actions_destroy(&actions);
    return failure;
}

ssize_t foo_process_write(int fd, const void *bytes, size_t len) {
#ifdef __APPLE__
    return write(fd, bytes, len);
#else
    // A broken stdin or lease is a per-operation error. Preserve the caller's
    // signal mask and any SIGPIPE already pending on this thread.
    sigset_t pipe_signal, old, pending;
    sigemptyset(&pipe_signal);
    sigaddset(&pipe_signal, SIGPIPE);
    int failure = pthread_sigmask(SIG_BLOCK, &pipe_signal, &old);
    if (failure != 0) {
        errno = failure;
        return -1;
    }
    if (sigpending(&pending) == -1) {
        int saved = errno;
        pthread_sigmask(SIG_SETMASK, &old, NULL);
        errno = saved;
        return -1;
    }
    ssize_t result = write(fd, bytes, len);
    int saved = errno;
    if (result == -1 && saved == EPIPE && sigismember(&pending, SIGPIPE) == 0) {
        const struct timespec immediate = {0};
        while (sigtimedwait(&pipe_signal, NULL, &immediate) == -1 && errno == EINTR) {}
    }
    pthread_sigmask(SIG_SETMASK, &old, NULL);
    errno = saved;
    return result;
#endif
}
