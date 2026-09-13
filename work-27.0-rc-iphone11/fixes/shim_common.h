#ifndef USBLITER8_SHIM_COMMON_H
#define USBLITER8_SHIM_COMMON_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

void *ul8_security_symbol(const char *name);
CFTypeRef ul8_security_constant(const char *name);

bool ul8_cf_equal(CFTypeRef left, CFTypeRef right);
bool ul8_dictionary_bool(CFDictionaryRef dictionary, CFTypeRef key);

bool ul8_read_file(const char *path, CFDataRef *data_out);
bool ul8_atomic_write_data(const char *path, CFDataRef data, mode_t mode);

void ul8_log(const char *component, const char *format, ...)
    __attribute__((format(printf, 2, 3)));

#ifndef USBLITER8_NO_INTERPOSE
#define UL8_INTERPOSE(replacement, replacee)                                   \
  __attribute__((used)) static struct {                                        \
    const void *replacement;                                                   \
    const void *replacee;                                                      \
  } _ul8_interpose_##replacee                                                  \
      __attribute__((section("__DATA,__interpose"))) = {                       \
          (const void *)(uintptr_t)&replacement,                               \
          (const void *)(uintptr_t)&replacee}
#else
#define UL8_INTERPOSE(replacement, replacee)
#endif

#endif
