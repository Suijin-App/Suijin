#ifndef MERCURY_TERMINAL_PTY_H
#define MERCURY_TERMINAL_PTY_H

#include <sys/types.h>

/// Step of the child setup that failed (reported through `stage_out`).
enum {
    MERCURY_TERMINAL_STAGE_NONE = 0,
    MERCURY_TERMINAL_STAGE_PTY = 1,
    MERCURY_TERMINAL_STAGE_FORK = 2,
    MERCURY_TERMINAL_STAGE_SESSION = 3,
    MERCURY_TERMINAL_STAGE_CHDIR = 4,
    MERCURY_TERMINAL_STAGE_EXEC = 5,
};

/// Starts `path` under a new pseudo-terminal of `rows` x `cols`.
///
/// The child becomes a session leader with the PTY as its controlling terminal and stdin/stdout/stderr; it gets an
/// empty signal mask, default dispositions for every signal and no other descriptors, then changes to `cwd` and
/// execs. Between fork and exec only async-signal-safe calls run. A failure up to and including `execve` is reported
/// back through a close-on-exec pipe; the failed child is reaped.
///
/// Returns 0 and sets `*pid_out`, `*master_out` (close-on-exec, non-blocking) and `*slave_out` (close-on-exec), or
/// returns an errno value and sets `*stage_out` to the failing `MERCURY_TERMINAL_STAGE_*`.
///
/// The caller keeps `*slave_out` open until it has read the child's last output: when the last slave descriptor
/// closes while output is still queued (the child exits under a slow reader), the tty may discard that output.
int mercury_terminal_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                           unsigned short rows, unsigned short cols,
                           pid_t *pid_out, int *master_out, int *slave_out, int *stage_out);

#endif
