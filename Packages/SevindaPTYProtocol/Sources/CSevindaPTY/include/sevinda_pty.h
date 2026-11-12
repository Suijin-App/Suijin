#ifndef MERCURY_PTY_H
#define MERCURY_PTY_H

#include <sys/types.h>

/// Failure stages reported through `mercury_pty_spawn_result.stage`.
enum {
    MERCURY_PTY_STAGE_NONE = 0,
    MERCURY_PTY_STAGE_OPENPT = 1,   // posix_openpt / grantpt / unlockpt / ptsname_r / opening the slave
    MERCURY_PTY_STAGE_PIPE = 2,     // status pipe creation
    MERCURY_PTY_STAGE_FORK = 3,
    MERCURY_PTY_STAGE_SETSID = 4,   // child: setsid or TIOCSCTTY
    MERCURY_PTY_STAGE_CHDIR = 5,    // child: chdir(cwd)
    MERCURY_PTY_STAGE_EXEC = 6,     // child: execve
};

typedef struct {
    pid_t pid;        // child pid, > 0 on success
    int master_fd;    // nonblocking, close-on-exec master side
    int slave_fd;     // close-on-exec slave side kept by the parent so pending output survives the child's exit
    int stage;        // MERCURY_PTY_STAGE_* on failure, MERCURY_PTY_STAGE_NONE on success
    int error_number; // errno of the failing stage
} mercury_pty_spawn_result;

/// Opens a pseudo terminal and starts `path` on it as a new session leader with the slave as its controlling
/// terminal (setsid + TIOCSCTTY) and as stdin/stdout/stderr. Every other descriptor is closed in the child, signal
/// dispositions and the signal mask are reset to defaults. `argv` and `envp` are NULL-terminated. Returns 0 on
/// success, -1 on failure (details in `result`). A child that failed to chdir or exec is reaped before returning.
int mercury_pty_spawn(const char *path,
                      char *const argv[],
                      char *const envp[],
                      const char *cwd,
                      unsigned short cols,
                      unsigned short rows,
                      mercury_pty_spawn_result *result);

/// Applies a window size to the terminal behind `fd` (TIOCSWINSZ). Returns 0 or -1 with errno set.
int mercury_pty_set_window_size(int fd, unsigned short cols, unsigned short rows);

/// Decodes a `waitpid` status into an exit code: the exit status for a normal exit, 128 + signal for a signal death.
int mercury_pty_exit_code(int wait_status);

#endif
