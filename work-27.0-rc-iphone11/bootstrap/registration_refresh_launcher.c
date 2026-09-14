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

static const char *const kUICache = "/var/jb/usr/bin/uicache";
static const char *const kLog =
    "/private/var/tmp/usbliter8-refresh-apps.log";
static const char *const kDone =
    "/private/var/tmp/usbliter8-refresh-apps.done";

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

static int mark_complete(void) {
    int fd = open(kDone, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        log_message("could not create completion marker: %s", strerror(errno));
        return -1;
    }
    static const char complete[] = "uicache -a -r completed\n";
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

int main(void) {
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
        return 0;
    }
    if (access(kUICache, X_OK) != 0) {
        log_message("uicache is unavailable: %s", strerror(errno));
        return 1;
    }

    /* launchd_cache_loader runs early. Give normal LaunchServices and
       SpringBoard time to reach their steady state before rebuilding. */
    log_message("waiting 60 seconds for normal userland");
    sleep(60);

    for (int attempt = 1; attempt <= 4; ++attempt) {
        pid_t child = -1;
        char *const arguments[] = {
            (char *)kUICache,
            (char *)"-a",
            (char *)"-r",
            NULL,
        };
        log_message("starting source-documented uicache -a -r (attempt %d)",
                    attempt);
        int spawn_result = posix_spawn(&child, kUICache, NULL, NULL, arguments,
                                       environ);
        if (spawn_result != 0) {
            log_message("posix_spawn failed: %s", strerror(spawn_result));
        } else {
            int status = 0;
            if (waitpid(child, &status, 0) < 0) {
                log_message("waitpid failed: %s", strerror(errno));
            } else if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
                log_message("uicache -a -r completed successfully");
                return mark_complete() == 0 ? 0 : 1;
            } else if (WIFEXITED(status)) {
                log_message("refresh-all exited with status %d",
                            WEXITSTATUS(status));
            } else if (WIFSIGNALED(status)) {
                log_message("refresh-all was terminated by signal %d",
                            WTERMSIG(status));
            } else {
                log_message("refresh-all ended with wait status 0x%x", status);
            }
        }

        if (attempt != 4) {
            sleep(15);
        }
    }

    log_message("uicache -a -r did not complete after four attempts");
    return 1;
}
