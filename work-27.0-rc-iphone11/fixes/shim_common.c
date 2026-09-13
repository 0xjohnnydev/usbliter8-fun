#include "shim_common.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <syslog.h>
#include <unistd.h>

#define UL8_MAX_FILE_SIZE (1024U * 1024U)

static pthread_once_t security_once = PTHREAD_ONCE_INIT;
static void *security_handle;

static void ul8_open_security(void) {
  security_handle =
      dlopen("/System/Library/Frameworks/Security.framework/Security",
             RTLD_LAZY | RTLD_LOCAL);
}

void *ul8_security_symbol(const char *name) {
  pthread_once(&security_once, ul8_open_security);
  if (security_handle == NULL) {
    return NULL;
  }
  return dlsym(security_handle, name);
}

CFTypeRef ul8_security_constant(const char *name) {
  const CFTypeRef *address = (const CFTypeRef *)ul8_security_symbol(name);
  return address == NULL ? NULL : *address;
}

bool ul8_cf_equal(CFTypeRef left, CFTypeRef right) {
  return left != NULL && right != NULL &&
         (left == right || CFEqual(left, right));
}

bool ul8_dictionary_bool(CFDictionaryRef dictionary, CFTypeRef key) {
  if (dictionary == NULL || key == NULL) {
    return false;
  }
  return ul8_cf_equal(CFDictionaryGetValue(dictionary, key), kCFBooleanTrue);
}

bool ul8_read_file(const char *path, CFDataRef *data_out) {
  int descriptor = -1;
  struct stat attributes;
  UInt8 *bytes = NULL;
  CFDataRef data = NULL;
  bool success = false;

  if (path == NULL || data_out == NULL) {
    return false;
  }
  *data_out = NULL;

  descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0 || fstat(descriptor, &attributes) != 0 ||
      !S_ISREG(attributes.st_mode) || attributes.st_size <= 0 ||
      (uint64_t)attributes.st_size > UL8_MAX_FILE_SIZE) {
    goto out;
  }

  bytes = malloc((size_t)attributes.st_size);
  if (bytes == NULL) {
    goto out;
  }

  size_t offset = 0;
  while (offset < (size_t)attributes.st_size) {
    ssize_t count =
        read(descriptor, bytes + offset, (size_t)attributes.st_size - offset);
    if (count <= 0) {
      goto out;
    }
    offset += (size_t)count;
  }

  data = CFDataCreate(kCFAllocatorDefault, bytes, attributes.st_size);
  if (data == NULL) {
    goto out;
  }

  *data_out = data;
  data = NULL;
  success = true;

out:
  if (data != NULL) {
    CFRelease(data);
  }
  free(bytes);
  if (descriptor >= 0) {
    close(descriptor);
  }
  return success;
}

bool ul8_atomic_write_data(const char *path, CFDataRef data, mode_t mode) {
  char temporary[PATH_MAX];
  int descriptor = -1;
  bool success = false;

  if (path == NULL || data == NULL || CFGetTypeID(data) != CFDataGetTypeID()) {
    return false;
  }
  if (snprintf(temporary, sizeof(temporary), "%s.tmp.%d", path, getpid()) >=
      (int)sizeof(temporary)) {
    return false;
  }

  unlink(temporary);
  descriptor = open(temporary,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode);
  if (descriptor < 0 || fchmod(descriptor, mode) != 0) {
    goto out;
  }

  const UInt8 *bytes = CFDataGetBytePtr(data);
  size_t length = (size_t)CFDataGetLength(data);
  size_t offset = 0;
  while (offset < length) {
    ssize_t count = write(descriptor, bytes + offset, length - offset);
    if (count <= 0) {
      goto out;
    }
    offset += (size_t)count;
  }

  if (fsync(descriptor) != 0 || close(descriptor) != 0) {
    descriptor = -1;
    goto out;
  }
  descriptor = -1;

  if (rename(temporary, path) != 0 || chmod(path, mode) != 0) {
    goto out;
  }
  success = true;

out:
  if (descriptor >= 0) {
    close(descriptor);
  }
  if (!success) {
    unlink(temporary);
  }
  return success;
}

void ul8_log(const char *component, const char *format, ...) {
  char message[512];
  va_list arguments;

  va_start(arguments, format);
  vsnprintf(message, sizeof(message), format, arguments);
  va_end(arguments);

  syslog(LOG_NOTICE, "usbliter8[%s]: %s",
         component == NULL ? "shim" : component, message);
}
