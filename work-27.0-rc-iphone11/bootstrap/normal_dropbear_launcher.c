#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DROPBEAR_PATH "/var/jb/usr/local/bin/dropbear"
#define BOOTSTRAP_MARKER "/var/jb/.procursus_strapped"
#define HOST_KEY_PATH "/var/jb/etc/dropbear/dropbear_ecdsa_host_key"
#define AUTHORIZED_KEYS_PATH "/var/root/.ssh/authorized_keys"
#define PID_FILE_PATH "/var/run/usbliter8-dropbear.pid"

static const char *validated_port(int argc, char **argv) {
    const char *text = argc > 1 ? argv[1] : "22";
    char *end = NULL;
    errno = 0;
    long port = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || port < 1 || port > 65535) {
        fprintf(stderr, "usbliter8-dropbear-launcher: invalid port: %s\n", text);
        exit(64);
    }
    return text;
}

static int runtime_ready(void) {
    return access(BOOTSTRAP_MARKER, R_OK) == 0 &&
           access(DROPBEAR_PATH, X_OK) == 0 &&
           access(HOST_KEY_PATH, R_OK) == 0 &&
           access(AUTHORIZED_KEYS_PATH, R_OK) == 0;
}

int main(int argc, char **argv) {
    const char *port = validated_port(argc, argv);

    /*
     * launchd begins loading System jobs before the Data volume is guaranteed
     * to expose /var.  A ProgramArguments[0] below /var/jb can therefore fail
     * at spawn time and never reach Dropbear's own foreground loop.  This
     * launcher lives on System, so launchd can always start it; it waits for
     * the four exact Data-backed inputs and then replaces itself with the
     * audited upstream Dropbear binary.
     */
    for (unsigned int second = 0; second < 180; ++second) {
        if (runtime_ready()) {
            execl(DROPBEAR_PATH,
                  DROPBEAR_PATH,
                  "-F",
                  "-E",
                  "-s",
                  "-p",
                  port,
                  "-r",
                  HOST_KEY_PATH,
                  "-P",
                  PID_FILE_PATH,
                  (char *)NULL);
            fprintf(stderr,
                    "usbliter8-dropbear-launcher: exec %s failed: %s\n",
                    DROPBEAR_PATH,
                    strerror(errno));
            return 126;
        }
        sleep(1);
    }

    fprintf(stderr,
            "usbliter8-dropbear-launcher: Data runtime was not ready after 180 seconds\n");
    return 75;
}
