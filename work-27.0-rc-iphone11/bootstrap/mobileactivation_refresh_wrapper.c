#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static const char *const kActiveDaemon = "/usr/libexec/mobileactivationd";
static const char *const kOriginalDaemon =
    "/usr/libexec/mobileactivationd.usbliter8-refresh-original";
static const char *const kHelper =
    "/usr/local/libexec/usbliter8-trollstorehelper";
static const char *const kUICache = "/var/jb/usr/bin/uicache";
static const char *const kDone =
    "/private/var/tmp/usbliter8-refresh-apps.done";
static const char *const kLog =
    "/private/var/tmp/usbliter8-mobileactivation-refresh.log";

static void log_message(const char *format, ...) {
    char timestamp[32] = "unknown-time";
    time_t now = time(NULL);
    struct tm tm_value;
    if (localtime_r(&now, &tm_value) != NULL) {
        (void)strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S",
                       &tm_value);
    }

    dprintf(STDERR_FILENO, "[%s] ", timestamp);
    va_list arguments;
    va_start(arguments, format);
    vdprintf(STDERR_FILENO, format, arguments);
    va_end(arguments);
    dprintf(STDERR_FILENO, "\n");
}

static int run_and_wait(const char *path, char *const arguments[]) {
    pid_t child = -1;
    int spawn_result = posix_spawn(&child, path, NULL, NULL, arguments, environ);
    if (spawn_result != 0) {
        log_message("could not spawn %s: %s", path, strerror(spawn_result));
        return -1;
    }

    int status = 0;
    if (waitpid(child, &status, 0) < 0) {
        log_message("waitpid for %s failed: %s", path, strerror(errno));
        return -1;
    }
    if (WIFEXITED(status)) {
        int exit_status = WEXITSTATUS(status);
        log_message("%s exited with status %d", path, exit_status);
        return exit_status;
    }
    if (WIFSIGNALED(status)) {
        log_message("%s was terminated by signal %d", path, WTERMSIG(status));
    } else {
        log_message("%s ended with wait status 0x%x", path, status);
    }
    return -1;
}

static int mark_complete(void) {
    int fd = open(kDone, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        log_message("could not create completion marker: %s", strerror(errno));
        return -1;
    }
    static const char complete[] = "normal-userland refresh completed\n";
    ssize_t written = write(fd, complete, sizeof(complete) - 1);
    int saved_errno = errno;
    close(fd);
    if (written != (ssize_t)(sizeof(complete) - 1)) {
        log_message("could not write completion marker: %s",
                    strerror(saved_errno));
        return -1;
    }
    sync();
    return 0;
}

static void refresh_child(void) {
    (void)setsid();
    long descriptor_limit = sysconf(_SC_OPEN_MAX);
    if (descriptor_limit < 0 || descriptor_limit > 65536) {
        descriptor_limit = 1024;
    }
    for (int fd = 3; fd < descriptor_limit; ++fd) {
        close(fd);
    }

    int log_fd = open(kLog, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (log_fd >= 0) {
        (void)dup2(log_fd, STDOUT_FILENO);
        (void)dup2(log_fd, STDERR_FILENO);
        if (log_fd > STDERR_FILENO) {
            close(log_fd);
        }
    }

    if (access(kDone, F_OK) == 0) {
        log_message("completion marker exists; nothing to do");
        _exit(0);
    }

    log_message("mobileactivationd launch observed; waiting for userland");
    sleep(30);

    int uicache_result = -1;
    if (access(kUICache, X_OK) == 0) {
        char *const uicache_arguments[] = {
            (char *)kUICache,
            (char *)"-a",
            NULL,
        };
        uicache_result = run_and_wait(kUICache, uicache_arguments);
    } else {
        log_message("uicache is unavailable: %s", strerror(errno));
    }

    int helper_result = -1;
    for (int attempt = 1; attempt <= 3; ++attempt) {
        if (access(kHelper, X_OK) != 0) {
            log_message("trollstorehelper is unavailable: %s", strerror(errno));
            break;
        }
        char *const helper_arguments[] = {
            (char *)kHelper,
            (char *)"refresh-all",
            NULL,
        };
        log_message("starting 34306 refresh-all attempt %d", attempt);
        helper_result = run_and_wait(kHelper, helper_arguments);
        if (helper_result == 0) {
            break;
        }
        sleep(10);
    }

    if (uicache_result == 0 || helper_result == 0) {
        if (mark_complete() == 0) {
            if (rename(kOriginalDaemon, kActiveDaemon) == 0) {
                log_message("restored the patched mobileactivationd in place");
                sync();
            } else {
                log_message("deferred daemon restoration: %s", strerror(errno));
            }
            _exit(0);
        }
    }

    log_message("neither normal-userland registration method succeeded");
    _exit(1);
}

int main(int argc, char **argv, char **envp) {
    (void)argc;
    if (access(kOriginalDaemon, X_OK) != 0) {
        dprintf(STDERR_FILENO, "missing original mobileactivationd: %s\n",
                strerror(errno));
        return 127;
    }

    pid_t child = fork();
    if (child == 0) {
        refresh_child();
    }

    execve(kOriginalDaemon, argv, envp);
    dprintf(STDERR_FILENO, "could not exec original mobileactivationd: %s\n",
            strerror(errno));
    return 127;
}
