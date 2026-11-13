#include "suijin_terminal_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

// Serializes spawns from this module so the short window in which new descriptors lack FD_CLOEXEC never overlaps
// another spawn here. The child closes every inherited descriptor anyway.
static pthread_mutex_t spawn_lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    int stage;
    int error_number;
} child_failure;

static void set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags >= 0) fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

// Child side: async-signal-safe calls only.
static void child_fail(int status_fd, int stage) {
    child_failure failure = { stage, errno };
    ssize_t ignored = write(status_fd, &failure, sizeof(failure));
    (void)ignored;
    _exit(stage == SUIJIN_TERMINAL_STAGE_EXEC ? 127 : 126);
}

static void child_run(const char *path, char *const argv[], char *const envp[], const char *cwd,
                      int slave_fd, int status_fd, int max_fd) {
    if (setsid() < 0) child_fail(status_fd, SUIJIN_TERMINAL_STAGE_SESSION);
    if (ioctl(slave_fd, TIOCSCTTY, 0) < 0) child_fail(status_fd, SUIJIN_TERMINAL_STAGE_SESSION);
    if (dup2(slave_fd, STDIN_FILENO) < 0 || dup2(slave_fd, STDOUT_FILENO) < 0 || dup2(slave_fd, STDERR_FILENO) < 0) {
        child_fail(status_fd, SUIJIN_TERMINAL_STAGE_SESSION);
    }
    // Other terminals' masters must not leak into this child: an inherited master keeps that PTY alive after its
    // tab closed.
    for (int fd = STDERR_FILENO + 1; fd < max_fd; fd++) {
        if (fd != status_fd) close(fd);
    }

    // Dispositions an app set to "ignore" survive exec (an ignored SIGPIPE breaks `yes | head`).
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

    if (cwd != NULL && cwd[0] != '\0' && chdir(cwd) < 0) child_fail(status_fd, SUIJIN_TERMINAL_STAGE_CHDIR);
    execve(path, argv, envp);
    child_fail(status_fd, SUIJIN_TERMINAL_STAGE_EXEC);
}

int suijin_terminal_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                           unsigned short rows, unsigned short cols,
                           pid_t *pid_out, int *master_out, int *slave_out, int *stage_out) {
    *stage_out = SUIJIN_TERMINAL_STAGE_NONE;
    struct winsize window;
    memset(&window, 0, sizeof(window));
    window.ws_row = rows > 0 ? rows : 1;
    window.ws_col = cols > 0 ? cols : 1;
    long open_max = sysconf(_SC_OPEN_MAX);
    int max_fd = (open_max > 0 && open_max < 65536) ? (int)open_max : 65536;

    pthread_mutex_lock(&spawn_lock);
    int master = -1, slave = -1;
    if (openpty(&master, &slave, NULL, NULL, &window) < 0) {
        int error = errno;
        pthread_mutex_unlock(&spawn_lock);
        *stage_out = SUIJIN_TERMINAL_STAGE_PTY;
        return error;
    }
    set_cloexec(master);
    set_cloexec(slave);

    int status_pipe[2];
    if (pipe(status_pipe) < 0) {
        int error = errno;
        close(master);
        close(slave);
        pthread_mutex_unlock(&spawn_lock);
        *stage_out = SUIJIN_TERMINAL_STAGE_FORK;
        return error;
    }
    set_cloexec(status_pipe[0]);
    set_cloexec(status_pipe[1]);

    pid_t pid = fork();
    if (pid == 0) {
        child_run(path, argv, envp, cwd, slave, status_pipe[1], max_fd);
    }
    int fork_error = errno;
    close(status_pipe[1]);
    pthread_mutex_unlock(&spawn_lock);

    if (pid < 0) {
        close(master);
        close(slave);
        close(status_pipe[0]);
        *stage_out = SUIJIN_TERMINAL_STAGE_FORK;
        return fork_error;
    }

    // EOF means exec succeeded (the pipe closed on exec); a full record means the child failed and exited.
    child_failure failure = { 0, 0 };
    ssize_t count;
    do {
        count = read(status_pipe[0], &failure, sizeof(failure));
    } while (count < 0 && errno == EINTR);
    close(status_pipe[0]);
    if (count == (ssize_t)sizeof(failure)) {
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        close(master);
        close(slave);
        *stage_out = failure.stage;
        return failure.error_number != 0 ? failure.error_number : EIO;
    }

    int flags = fcntl(master, F_GETFL);
    if (flags >= 0) fcntl(master, F_SETFL, flags | O_NONBLOCK);
    *pid_out = pid;
    *master_out = master;
    *slave_out = slave;
    return 0;
}
