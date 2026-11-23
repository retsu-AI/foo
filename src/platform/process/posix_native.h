#ifndef FOO_PROCESS_POSIX_NATIVE_H
#define FOO_PROCESS_POSIX_NATIVE_H

#include <stddef.h>
#include <sys/types.h>

enum { FOO_PROCESS_LEASE_FD = 3, FOO_PROCESS_STATUS_FD = 4 };
enum { FOO_PROCESS_STDIN, FOO_PROCESS_STDOUT, FOO_PROCESS_STDERR,
       FOO_PROCESS_LEASE, FOO_PROCESS_STATUS, FOO_PROCESS_PIPE_COUNT };
enum { FOO_PROCESS_READY = 1, FOO_PROCESS_EXITED, FOO_PROCESS_SIGNALLED, FOO_PROCESS_FAILED };
enum { FOO_PROCESS_INVALID = 1, FOO_PROCESS_UNAVAILABLE, FOO_PROCESS_LIMIT, FOO_PROCESS_IO };

int foo_process_pipes(int (*pipes)[2]);
int foo_process_spawn(pid_t *pid, const char *path, const int *fds, size_t fd_count,
                      char *const argv[], char *const envp[]);
ssize_t foo_process_write(int fd, const void *bytes, size_t len);

#endif
