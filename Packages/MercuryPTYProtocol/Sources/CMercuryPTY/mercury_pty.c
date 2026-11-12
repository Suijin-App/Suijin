#include "mercury_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

// Serializes spawns so the short windows in which freshly created descriptors lack FD_CLOEXEC never overlap
// with another spawn in this process. The child closes every inherited descriptor anyway.
static pthread_mutex_t spawn_lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    int stage;
    int error_number;
} child_failure;

static int set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void close_quietly(int fd) {
    if (fd >= 0) {
        int saved = errno;
        close(fd);
        errno = saved;
    }
}

// Runs in the forked child: only async-signal-safe calls from here on.
static void child_report_and_exit(int status_fd, int stage, int code) {
    child_failure failure = { stage, errno };
    ssize_t ignored = write(status_fd, &failure, sizeof(failure));
    (void)ignored;
    _exit(code);
}

static void child_run(const char *path, char *const argv[], char *const envp[], const char *cwd,
                      int slave_fd, int status_fd, int max_fd) {
    if (setsid() < 0) child_report_and_exit(status_fd, MERCURY_PTY_STAGE_SETSID, 126);
    if (ioctl(slave_fd, TIOCSCTTY, 0) < 0) child_report_and_exit(status_fd, MERCURY_PTY_STAGE_SETSID, 126);

    if (dup2(slave_fd, STDIN_FILENO) < 0 || dup2(slave_fd, STDOUT_FILENO) < 0 || dup2(slave_fd, STDERR_FILENO) < 0) {
        child_report_and_exit(status_fd, MERCURY_PTY_STAGE_SETSID, 126);
    }
    // dup2 clears FD_CLOEXEC on 0-2; everything else (including the master and the original slave) is closed.
    for (int fd = STDERR_FILENO + 1; fd < max_fd; fd++) {
        if (fd != status_fd) close(fd);
    }

    sigset_t empty;
    sigemptyset(&empty);
    sigprocmask(SIG_SETMASK, &empty, NULL);
    struct sigaction dfl;
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    for (int sig = 1; sig < NSIG; sig++) {
        if (sig != SIGKILL && sig != SIGSTOP) sigaction(sig, &dfl, NULL);
    }

    if (cwd != NULL && cwd[0] != '\0' && chdir(cwd) < 0) {
        child_report_and_exit(status_fd, MERCURY_PTY_STAGE_CHDIR, 126);
    }
    execve(path, argv, envp);
    child_report_and_exit(status_fd, MERCURY_PTY_STAGE_EXEC, 127);
}

static int fail(mercury_pty_spawn_result *result, int stage) {
    result->stage = stage;
    result->error_number = errno;
    return -1;
}

int mercury_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                      unsigned short cols, unsigned short rows, mercury_pty_spawn_result *result) {
    memset(result, 0, sizeof(*result));
    result->master_fd = -1;
    result->slave_fd = -1;

    // Highest descriptor to close in the child, computed before fork (getrlimit is not on the safe list).
    // Capped so a huge or unlimited soft limit does not turn the close loop into millions of syscalls.
    struct rlimit limit;
    int max_fd = 65536;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY && limit.rlim_cur < (rlim_t)max_fd) {
        max_fd = (int)limit.rlim_cur;
    }

    pthread_mutex_lock(&spawn_lock);

    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) {
        pthread_mutex_unlock(&spawn_lock);
        return fail(result, MERCURY_PTY_STAGE_OPENPT);
    }
    char slave_name[128];
    if (set_cloexec(master) < 0 || grantpt(master) < 0 || unlockpt(master) < 0 ||
        ptsname_r(master, slave_name, sizeof(slave_name)) != 0) {
        int saved = errno;
        close(master);
        pthread_mutex_unlock(&spawn_lock);
        errno = saved;
        return fail(result, MERCURY_PTY_STAGE_OPENPT);
    }
    int slave = open(slave_name, O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (slave < 0) {
        int saved = errno;
        close(master);
        pthread_mutex_unlock(&spawn_lock);
        errno = saved;
        return fail(result, MERCURY_PTY_STAGE_OPENPT);
    }

    // Terminal defaults: keep the kernel's cooked mode but declare UTF-8 input so line editing handles multibyte.
    struct termios tio;
    if (tcgetattr(slave, &tio) == 0) {
        tio.c_iflag |= IUTF8;
        tcsetattr(slave, TCSANOW, &tio);
    }
    struct winsize ws = { rows, cols, 0, 0 };
    ioctl(slave, TIOCSWINSZ, &ws);

    int status_pipe[2];
    if (pipe(status_pipe) < 0) {
        int saved = errno;
        close(master);
        close(slave);
        pthread_mutex_unlock(&spawn_lock);
        errno = saved;
        return fail(result, MERCURY_PTY_STAGE_PIPE);
    }
    set_cloexec(status_pipe[0]);
    set_cloexec(status_pipe[1]);

    pid_t pid = fork();
    if (pid < 0) {
        int saved = errno;
        close(master);
        close(slave);
        close(status_pipe[0]);
        close(status_pipe[1]);
        pthread_mutex_unlock(&spawn_lock);
        errno = saved;
        return fail(result, MERCURY_PTY_STAGE_FORK);
    }
    if (pid == 0) {
        child_run(path, argv, envp, cwd, slave, status_pipe[1], max_fd);
        _exit(127); // not reached
    }

    pthread_mutex_unlock(&spawn_lock);
    close(status_pipe[1]);

    // EOF means execve succeeded (the close-on-exec write end vanished); a full record means the child failed.
    child_failure failure;
    ssize_t got;
    do {
        got = read(status_pipe[0], &failure, sizeof(failure));
    } while (got < 0 && errno == EINTR);
    close(status_pipe[0]);

    if (got == (ssize_t)sizeof(failure)) {
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        close(master);
        close(slave);
        result->stage = failure.stage;
        result->error_number = failure.error_number;
        return -1;
    }

    if (set_nonblocking(master) < 0) {
        int saved = errno;
        kill(pid, SIGKILL);
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        close_quietly(master);
        close_quietly(slave);
        errno = saved;
        return fail(result, MERCURY_PTY_STAGE_OPENPT);
    }

    result->pid = pid;
    result->master_fd = master;
    result->slave_fd = slave;
    result->stage = MERCURY_PTY_STAGE_NONE;
    return 0;
}

int mercury_pty_set_window_size(int fd, unsigned short cols, unsigned short rows) {
    struct winsize ws = { rows, cols, 0, 0 };
    return ioctl(fd, TIOCSWINSZ, &ws);
}

int mercury_pty_exit_code(int wait_status) {
    if (WIFEXITED(wait_status)) return WEXITSTATUS(wait_status);
    if (WIFSIGNALED(wait_status)) return 128 + WTERMSIG(wait_status);
    return -1;
}
