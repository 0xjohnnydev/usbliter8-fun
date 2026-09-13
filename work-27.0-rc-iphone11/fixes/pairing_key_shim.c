#include "shim_common.h"

#include <Security/Security.h>
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define PAIRING_COMPONENT "pairing"
#define PAIRING_KEY_PATH                                                       \
  "/private/var/root/Library/Lockdown/usbliter8_pairing_key.der"

static pthread_mutex_t pairing_mutex = PTHREAD_MUTEX_INITIALIZER;

static const char *pairing_key_path(void) {
#ifdef USBLITER8_TESTING
  const char *override = getenv("USBLITER8_PAIRING_KEY_PATH");
  if (override != NULL && override[0] != '\0') {
    return override;
  }
#endif
  return PAIRING_KEY_PATH;
}

static bool pairing_query_matches(CFDictionaryRef query) {
  if (query == NULL || CFGetTypeID(query) != CFDictionaryGetTypeID()) {
    return false;
  }

  CFTypeRef access_group = CFDictionaryGetValue(query, kSecAttrAccessGroup);
  CFTypeRef label = CFDictionaryGetValue(query, kSecAttrLabel);
  CFTypeRef item_class = CFDictionaryGetValue(query, kSecClass);

  if (!ul8_cf_equal(access_group, CFSTR("lockdown-identities")) ||
      !ul8_cf_equal(label, CFSTR("com.apple.lockdown.pairingkeypair"))) {
    return false;
  }
  return item_class == NULL || ul8_cf_equal(item_class, kSecClassKey);
}

static SecKeyRef pairing_key_from_data(CFDataRef data) {
  int bits = 2048;
  CFNumberRef bit_count =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bits);
  if (bit_count == NULL) {
    return NULL;
  }

  const void *keys[] = {
      kSecAttrKeyType,
      kSecAttrKeyClass,
      kSecAttrKeySizeInBits,
  };
  const void *values[] = {
      kSecAttrKeyTypeRSA,
      kSecAttrKeyClassPrivate,
      bit_count,
  };
  CFDictionaryRef attributes = CFDictionaryCreate(
      kCFAllocatorDefault, keys, values, sizeof(keys) / sizeof(keys[0]),
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFRelease(bit_count);
  if (attributes == NULL) {
    return NULL;
  }

  CFErrorRef error = NULL;
  SecKeyRef key = SecKeyCreateWithData(data, attributes, &error);
  CFRelease(attributes);
  if (error != NULL) {
    CFRelease(error);
  }
  if (key == NULL) {
    return NULL;
  }

  SecKeyRef public_key = SecKeyCopyPublicKey(key);
  if (public_key == NULL) {
    CFRelease(key);
    return NULL;
  }
  CFRelease(public_key);
  return key;
}

static bool pairing_persist_key_locked(SecKeyRef key) {
  if (key == NULL || CFGetTypeID(key) != SecKeyGetTypeID()) {
    return false;
  }

  CFErrorRef error = NULL;
  CFDataRef bytes = SecKeyCopyExternalRepresentation(key, &error);
  if (error != NULL) {
    CFRelease(error);
  }
  if (bytes == NULL) {
    ul8_log(PAIRING_COMPONENT, "could not export the software RSA key");
    return false;
  }

  bool success = ul8_atomic_write_data(pairing_key_path(), bytes, 0600);
  CFRelease(bytes);
  if (!success) {
    ul8_log(PAIRING_COMPONENT, "could not persist the RSA key at %s",
            pairing_key_path());
  }
  return success;
}

static SecKeyRef pairing_generate_key_locked(void) {
  int bits = 2048;
  CFNumberRef bit_count =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bits);
  if (bit_count == NULL) {
    return NULL;
  }
  const void *keys[] = {kSecAttrKeyType, kSecAttrKeySizeInBits};
  const void *values[] = {kSecAttrKeyTypeRSA, bit_count};
  CFDictionaryRef parameters = CFDictionaryCreate(
      kCFAllocatorDefault, keys, values, sizeof(keys) / sizeof(keys[0]),
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFRelease(bit_count);
  if (parameters == NULL) {
    return NULL;
  }

  CFErrorRef error = NULL;
  /* dyld deliberately leaves the interposing image's own import untouched. */
  SecKeyRef key = SecKeyCreateRandomKey(parameters, &error);
  CFRelease(parameters);
  if (error != NULL) {
    CFRelease(error);
  }
  if (key == NULL) {
    ul8_log(PAIRING_COMPONENT, "software RSA generation failed");
    return NULL;
  }
  if (!pairing_persist_key_locked(key)) {
    CFRelease(key);
    return NULL;
  }
  ul8_log(PAIRING_COMPONENT, "created the persistent software RSA key");
  return key;
}

static SecKeyRef pairing_load_or_create_key_locked(void) {
  CFDataRef bytes = NULL;
  SecKeyRef key = NULL;

  if (ul8_read_file(pairing_key_path(), &bytes)) {
    key = pairing_key_from_data(bytes);
    CFRelease(bytes);
    if (key != NULL) {
      return key;
    }
    ul8_log(PAIRING_COMPONENT, "stored RSA key was invalid; replacing it");
  }
  return pairing_generate_key_locked();
}

OSStatus ul8_pair_SecItemCopyMatching(CFDictionaryRef query,
                                      CFTypeRef *result) {
  if (!pairing_query_matches(query)) {
    return SecItemCopyMatching(query, result);
  }

  if (result != NULL) {
    *result = NULL;
  }
  pthread_mutex_lock(&pairing_mutex);
  SecKeyRef key = pairing_load_or_create_key_locked();
  pthread_mutex_unlock(&pairing_mutex);
  if (key == NULL) {
    return errSecNotAvailable;
  }

  if (result != NULL) {
    *result = key;
  } else {
    CFRelease(key);
  }
  return errSecSuccess;
}

OSStatus ul8_pair_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
  if (!pairing_query_matches(attributes)) {
    return SecItemAdd(attributes, result);
  }

  if (result != NULL) {
    *result = NULL;
  }
  SecKeyRef key = (SecKeyRef)CFDictionaryGetValue(attributes, kSecValueRef);
  if (key == NULL || CFGetTypeID(key) != SecKeyGetTypeID()) {
    return errSecParam;
  }

  pthread_mutex_lock(&pairing_mutex);
  bool success = pairing_persist_key_locked(key);
  pthread_mutex_unlock(&pairing_mutex);
  return success ? errSecSuccess : errSecNotAvailable;
}

OSStatus ul8_pair_SecItemUpdate(CFDictionaryRef query,
                                CFDictionaryRef attributes_to_update) {
  if (!pairing_query_matches(query)) {
    return SecItemUpdate(query, attributes_to_update);
  }

  SecKeyRef key =
      (SecKeyRef)CFDictionaryGetValue(attributes_to_update, kSecValueRef);
  if (key == NULL || CFGetTypeID(key) != SecKeyGetTypeID()) {
    return errSecParam;
  }
  pthread_mutex_lock(&pairing_mutex);
  bool success = pairing_persist_key_locked(key);
  pthread_mutex_unlock(&pairing_mutex);
  return success ? errSecSuccess : errSecNotAvailable;
}

OSStatus ul8_pair_SecItemDelete(CFDictionaryRef query) {
  if (!pairing_query_matches(query)) {
    return SecItemDelete(query);
  }

  pthread_mutex_lock(&pairing_mutex);
  int result = unlink(pairing_key_path());
  int saved_errno = errno;
  pthread_mutex_unlock(&pairing_mutex);

  if (result == 0) {
    ul8_log(PAIRING_COMPONENT, "deleted the persistent software RSA key");
    return errSecSuccess;
  }
  return saved_errno == ENOENT ? errSecItemNotFound : errSecNotAvailable;
}

SecKeyRef ul8_pair_SecKeyCreateRandomKey(CFDictionaryRef parameters,
                                         CFErrorRef *error) {
  if (!pairing_query_matches(parameters)) {
    return SecKeyCreateRandomKey(parameters, error);
  }

  CFMutableDictionaryRef software_parameters =
      CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, parameters);
  if (software_parameters == NULL) {
    return NULL;
  }

  CFTypeRef system_keychain = ul8_security_constant("kSecUseSystemKeychain");
  if (system_keychain != NULL) {
    CFDictionaryRemoveValue(software_parameters, system_keychain);
  }
  CFDictionaryRemoveValue(software_parameters, kSecAttrAccessGroup);
  CFDictionaryRemoveValue(software_parameters, kSecAttrLabel);
  CFDictionaryRemoveValue(software_parameters, kSecAttrAccessible);
  CFDictionaryRemoveValue(software_parameters, kSecAttrIsPermanent);

  SecKeyRef key = SecKeyCreateRandomKey(software_parameters, error);
  CFRelease(software_parameters);
  return key;
}

__attribute__((constructor)) static void pairing_shim_loaded(void) {
  ul8_log(PAIRING_COMPONENT, "24A435 pairing shim loaded");
}

#ifdef USBLITER8_TESTING
__attribute__((visibility("default"))) int usbliter8_pairing_test_anchor(void) {
  return 1;
}
#endif

UL8_INTERPOSE(ul8_pair_SecItemCopyMatching, SecItemCopyMatching);
UL8_INTERPOSE(ul8_pair_SecItemAdd, SecItemAdd);
UL8_INTERPOSE(ul8_pair_SecItemUpdate, SecItemUpdate);
UL8_INTERPOSE(ul8_pair_SecItemDelete, SecItemDelete);
UL8_INTERPOSE(ul8_pair_SecKeyCreateRandomKey, SecKeyCreateRandomKey);
