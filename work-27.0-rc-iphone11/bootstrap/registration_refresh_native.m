#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* libproc is present in the iOS 27 SDK, but its public header is not. */
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer,
                         int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);

#define PROC_ALL_PIDS 1

static const char *const kLog =
    "/private/var/tmp/usbliter8-native-refresh.log";
static const char *const kDone =
    "/private/var/tmp/usbliter8-native-refresh.done";
static const char *const kSileoPath = "/Applications/Sileo.app";
static const char *const kIconsCache =
    "/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/"
    "Library/Caches/com.apple.IconsCache";

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

static bool load_image(const char *path) {
    dlerror();
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        const char *error = dlerror();
        log_message("dlopen failed for %s: %s", path,
                    error != NULL ? error : "unknown error");
        return false;
    }
    return true;
}

static void clear_icons_cache(void) {
    NSString *path = [NSString stringWithUTF8String:kIconsCache];
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:path]) {
        log_message("LaunchServices icons cache is already absent");
        return;
    }

    NSError *error = nil;
    if ([manager removeItemAtPath:path error:&error]) {
        log_message("removed the stale LaunchServices icons cache");
    } else {
        log_message("could not remove the LaunchServices icons cache: %s",
                    [[error description] UTF8String]);
    }
}

static bool sileo_is_registered(void) {
    Class proxy_class = objc_getClass("LSApplicationProxy");
    SEL proxy_selector = sel_registerName("applicationProxyForIdentifier:");
    SEL bundle_url_selector = sel_registerName("bundleURL");
    if (proxy_class == Nil ||
        class_getClassMethod(proxy_class, proxy_selector) == NULL ||
        class_getInstanceMethod(proxy_class, bundle_url_selector) == NULL) {
        log_message("Sileo registration verification selectors are unavailable");
        return false;
    }

    typedef id (*SendId)(id, SEL);
    typedef id (*SendIdArgument)(id, SEL, id);
    id proxy = ((SendIdArgument)objc_msgSend)(
        (id)proxy_class, proxy_selector, @"org.coolstar.SileoStore");
    if (proxy == nil) {
        log_message("Sileo has no LaunchServices proxy");
        return false;
    }

    NSURL *bundle_url =
        ((SendId)objc_msgSend)(proxy, bundle_url_selector);
    NSString *bundle_path = [bundle_url path];
    bool matches = [bundle_path isEqualToString:@"/Applications/Sileo.app"];
    log_message("Sileo LaunchServices path is %s",
                bundle_path != nil ? [bundle_path UTF8String] : "(nil)");
    return matches;
}

static bool rebuild_launch_services(void) {
    static const char *const core_services =
        "/System/Library/Frameworks/CoreServices.framework/CoreServices";
    if (!load_image(core_services)) {
        return false;
    }

    Class workspace_class = objc_getClass("LSApplicationWorkspace");
    if (workspace_class == Nil) {
        log_message("LSApplicationWorkspace is unavailable");
        return false;
    }

    SEL default_workspace = sel_registerName("defaultWorkspace");
    SEL rebuild = sel_registerName(
        "_LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:");
    SEL register_application = sel_registerName("registerApplication:");

    if (class_getClassMethod(workspace_class, default_workspace) == NULL ||
        class_getInstanceMethod(workspace_class, rebuild) == NULL) {
        log_message("required iOS 27 LaunchServices selectors are unavailable");
        return false;
    }

    typedef id (*SendId)(id, SEL);
    typedef BOOL (*SendRebuild)(id, SEL, BOOL, BOOL, BOOL);
    typedef BOOL (*SendRegister)(id, SEL, id);

    id workspace = ((SendId)objc_msgSend)((id)workspace_class,
                                          default_workspace);
    if (workspace == nil) {
        log_message("default LaunchServices workspace is nil");
        return false;
    }

    clear_icons_cache();
    log_message("rebuilding system, internal, and user application databases");
    BOOL rebuilt = ((SendRebuild)objc_msgSend)(workspace, rebuild, YES, YES,
                                               YES);
    log_message("LaunchServices rebuild returned %s", rebuilt ? "success"
                                                               : "failure");

    BOOL sileo_registered = NO;
    if (access(kSileoPath, F_OK) == 0 &&
        class_getInstanceMethod(workspace_class, register_application) !=
            NULL) {
        NSURL *sileo_url =
            [NSURL fileURLWithPath:@"/Applications/Sileo.app" isDirectory:YES];
        sileo_registered = ((SendRegister)objc_msgSend)(
            workspace, register_application, sileo_url);
        log_message("explicit Sileo registration returned %s",
                    sileo_registered ? "success" : "failure");
    } else if (access(kSileoPath, F_OK) != 0) {
        log_message("Sileo bundle is unavailable: %s", strerror(errno));
    }

    sleep(2);
    bool verified = sileo_is_registered();
    log_message("Sileo registration verification returned %s",
                verified ? "success" : "failure");
    return rebuilt && verified;
}

static pid_t find_process(const char *expected_name) {
    pid_t pids[4096];
    int bytes =
        proc_listpids(PROC_ALL_PIDS, 0, pids, (int)sizeof(pids));
    if (bytes <= 0) {
        return 0;
    }

    size_t count = (size_t)bytes / sizeof(pids[0]);
    for (size_t index = 0; index < count; ++index) {
        pid_t pid = pids[index];
        if (pid <= 1) {
            continue;
        }

        char name[256] = {0};
        if (proc_name(pid, name, sizeof(name)) > 0 &&
            strcmp(name, expected_name) == 0) {
            return pid;
        }
    }
    return 0;
}

static bool request_source_style_respring(void) {
    static const char *const frontboard =
        "/System/Library/PrivateFrameworks/FrontBoardServices.framework/"
        "FrontBoardServices";
    static const char *const springboard =
        "/System/Library/PrivateFrameworks/SpringBoardServices.framework/"
        "SpringBoardServices";

    if (!load_image(frontboard) || !load_image(springboard)) {
        return false;
    }

    Class action_class = objc_getClass("SBSRelaunchAction");
    Class service_class = objc_getClass("FBSSystemService");
    SEL action_selector =
        sel_registerName("actionWithReason:options:targetURL:");
    SEL shared_service = sel_registerName("sharedService");
    SEL send_actions = sel_registerName("sendActions:withResult:");

    if (action_class == Nil || service_class == Nil ||
        class_getClassMethod(action_class, action_selector) == NULL ||
        class_getClassMethod(service_class, shared_service) == NULL ||
        class_getInstanceMethod(service_class, send_actions) == NULL) {
        log_message("source-style respring classes or selectors are unavailable");
        return false;
    }

    typedef id (*SendId)(id, SEL);
    typedef id (*SendAction)(id, SEL, id, NSUInteger, id);
    typedef void (*SendActions)(id, SEL, id, id);

    const NSUInteger restart_render_server = 1U << 0;
    const NSUInteger fade_to_black = 1U << 2;
    id action = ((SendAction)objc_msgSend)(
        (id)action_class, action_selector,
        @"usbliter8 LaunchServices registration", restart_render_server |
                                                       fade_to_black,
        nil);
    id service =
        ((SendId)objc_msgSend)((id)service_class, shared_service);
    if (action == nil || service == nil) {
        log_message("could not create the source-style respring request");
        return false;
    }

    NSSet *actions = [NSSet setWithObject:action];
    log_message("sending source-style FrontBoard respring request");
    ((SendActions)objc_msgSend)(service, send_actions, actions, nil);
    return true;
}

static void ensure_visible_respring(void) {
    pid_t original_backboardd = find_process("backboardd");
    bool requested = request_source_style_respring();
    sleep(4);

    pid_t current_backboardd = find_process("backboardd");
    if (original_backboardd > 1 && current_backboardd == original_backboardd) {
        pid_t springboard = find_process("SpringBoard");
        if (springboard > 1) {
            log_message("FrontBoard did not relaunch; terminating SpringBoard %d",
                        springboard);
            (void)kill(springboard, SIGKILL);
        }
        log_message("terminating unchanged backboardd %d", current_backboardd);
        (void)kill(current_backboardd, SIGKILL);
    } else if (requested) {
        log_message("FrontBoard respring changed the backboardd process");
    } else {
        log_message("no backboardd process was available for fallback respring");
    }
}

static bool mark_complete(void) {
    int fd = open(kDone, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        log_message("could not create completion marker: %s", strerror(errno));
        return false;
    }

    static const char complete[] =
        "native arm64e LaunchServices refresh completed\n";
    ssize_t written = write(fd, complete, sizeof(complete) - 1);
    int saved_errno = errno;
    close(fd);
    if (written != (ssize_t)(sizeof(complete) - 1)) {
        log_message("could not write completion marker: %s",
                    strerror(saved_errno));
        return false;
    }
    sync();
    return true;
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

    @autoreleasepool {
        if (access(kDone, F_OK) == 0) {
            log_message("native completion marker exists; nothing to do");
            return 0;
        }

        log_message("native arm64e runner started; waiting 60 seconds");
        sleep(60);

        for (int attempt = 1; attempt <= 3; ++attempt) {
            log_message("starting native LaunchServices refresh attempt %d",
                        attempt);
            if (rebuild_launch_services()) {
                if (!mark_complete()) {
                    return 1;
                }
                log_message("native LaunchServices refresh completed");
                ensure_visible_respring();
                return 0;
            }
            if (attempt != 3) {
                sleep(10);
            }
        }

        log_message("native LaunchServices refresh failed after three attempts");
        return 1;
    }
}
