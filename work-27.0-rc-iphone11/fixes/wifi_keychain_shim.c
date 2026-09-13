#include "shim_common.h"

#include <Security/Security.h>
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>

#define WIFI_COMPONENT "wifi"
#define WIFI_PASSWORD_PATH                                                     \
  "/private/var/preferences/SystemConfiguration/"                              \
  "com.usbliter8.wifi-passwords.plist"

static pthread_mutex_t wifi_mutex = PTHREAD_MUTEX_INITIALIZER;

static const char *wifi_password_path(void) {
#ifdef USBLITER8_TESTING
  const char *override = getenv("USBLITER8_WIFI_PASSWORD_PATH");
  if (override != NULL && override[0] != '\0') {
    return override;
  }
#endif
  return WIFI_PASSWORD_PATH;
}

static bool wifi_query_matches(CFDictionaryRef query) {
  if (query == NULL || CFGetTypeID(query) != CFDictionaryGetTypeID()) {
    return false;
  }

  CFTypeRef service = CFDictionaryGetValue(query, kSecAttrService);
  CFTypeRef item_class = CFDictionaryGetValue(query, kSecClass);
  if (!ul8_cf_equal(service, CFSTR("AirPort"))) {
    return false;
  }
  return item_class == NULL ||
         ul8_cf_equal(item_class, kSecClassGenericPassword);
}

static CFStringRef wifi_account(CFDictionaryRef query) {
  CFTypeRef account =
      query == NULL ? NULL : CFDictionaryGetValue(query, kSecAttrAccount);
  return account != NULL && CFGetTypeID(account) == CFStringGetTypeID()
             ? (CFStringRef)account
             : NULL;
}

static CFMutableDictionaryRef wifi_load_store_locked(void) {
  CFDataRef bytes = NULL;
  if (!ul8_read_file(wifi_password_path(), &bytes)) {
    return CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                     &kCFTypeDictionaryKeyCallBacks,
                                     &kCFTypeDictionaryValueCallBacks);
  }

  CFErrorRef error = NULL;
  CFPropertyListRef property_list = CFPropertyListCreateWithData(
      kCFAllocatorDefault, bytes, kCFPropertyListMutableContainersAndLeaves,
      NULL, &error);
  CFRelease(bytes);
  if (error != NULL) {
    CFRelease(error);
  }

  if (property_list == NULL ||
      CFGetTypeID(property_list) != CFDictionaryGetTypeID()) {
    if (property_list != NULL) {
      CFRelease(property_list);
    }
    ul8_log(WIFI_COMPONENT, "credential store was invalid");
    return NULL;
  }
  return (CFMutableDictionaryRef)property_list;
}

static bool wifi_write_store_locked(CFDictionaryRef store) {
  CFErrorRef error = NULL;
  CFDataRef bytes = CFPropertyListCreateData(
      kCFAllocatorDefault, store, kCFPropertyListBinaryFormat_v1_0, 0, &error);
  if (error != NULL) {
    CFRelease(error);
  }
  if (bytes == NULL) {
    return false;
  }

  bool success = ul8_atomic_write_data(wifi_password_path(), bytes, 0600);
  CFRelease(bytes);
  if (!success) {
    ul8_log(WIFI_COMPONENT, "could not write credential store at %s",
            wifi_password_path());
  }
  return success;
}

static OSStatus wifi_store_password(CFDictionaryRef query,
                                    CFDictionaryRef values) {
  CFStringRef account = wifi_account(query);
  CFTypeRef password =
      values == NULL ? NULL : CFDictionaryGetValue(values, kSecValueData);
  if (account == NULL || password == NULL ||
      CFGetTypeID(password) != CFDataGetTypeID()) {
    return errSecParam;
  }

  pthread_mutex_lock(&wifi_mutex);
  CFMutableDictionaryRef store = wifi_load_store_locked();
  bool success = false;
  if (store != NULL) {
    CFDictionarySetValue(store, account, password);
    success = wifi_write_store_locked(store);
    CFRelease(store);
  }
  pthread_mutex_unlock(&wifi_mutex);

  if (success) {
    ul8_log(WIFI_COMPONENT, "stored one AirPort credential");
    return errSecSuccess;
  }
  return errSecNotAvailable;
}

OSStatus ul8_wifi_SecItemCopyMatching(CFDictionaryRef query,
                                      CFTypeRef *result) {
  if (!wifi_query_matches(query)) {
    return SecItemCopyMatching(query, result);
  }

  if (result != NULL) {
    *result = NULL;
  }
  CFStringRef account = wifi_account(query);
  if (account == NULL) {
    return SecItemCopyMatching(query, result);
  }

  pthread_mutex_lock(&wifi_mutex);
  CFMutableDictionaryRef store = wifi_load_store_locked();
  CFDataRef password =
      store == NULL ? NULL : (CFDataRef)CFDictionaryGetValue(store, account);
  if (password != NULL && CFGetTypeID(password) == CFDataGetTypeID()) {
    CFRetain(password);
  } else {
    password = NULL;
  }
  if (store != NULL) {
    CFRelease(store);
  }
  pthread_mutex_unlock(&wifi_mutex);

  if (password == NULL) {
#ifdef USBLITER8_TESTING
    return errSecItemNotFound;
#else
    return SecItemCopyMatching(query, result);
#endif
  }

  bool wants_data = ul8_dictionary_bool(query, kSecReturnData);
  bool wants_attributes = ul8_dictionary_bool(query, kSecReturnAttributes);
  if (result != NULL && wants_attributes) {
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (attributes == NULL) {
      CFRelease(password);
      return errSecAllocate;
    }
    CFDictionarySetValue(attributes, kSecAttrAccount, account);
    CFDictionarySetValue(attributes, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(attributes, kSecAttrService, CFSTR("AirPort"));
    if (wants_data) {
      CFDictionarySetValue(attributes, kSecValueData, password);
    }
    *result = attributes;
  } else if (result != NULL && wants_data) {
    *result = CFRetain(password);
  }
  CFRelease(password);
  return errSecSuccess;
}

OSStatus ul8_wifi_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
  if (!wifi_query_matches(attributes) || wifi_account(attributes) == NULL) {
    return SecItemAdd(attributes, result);
  }
  if (result != NULL) {
    *result = NULL;
  }
  return wifi_store_password(attributes, attributes);
}

OSStatus ul8_wifi_SecItemUpdate(CFDictionaryRef query,
                                CFDictionaryRef attributes_to_update) {
  if (!wifi_query_matches(query) || wifi_account(query) == NULL) {
    return SecItemUpdate(query, attributes_to_update);
  }
  return wifi_store_password(query, attributes_to_update);
}

OSStatus ul8_wifi_SecItemDelete(CFDictionaryRef query) {
  if (!wifi_query_matches(query)) {
    return SecItemDelete(query);
  }

  CFStringRef account = wifi_account(query);
  bool removed = false;
  bool write_succeeded = false;

  pthread_mutex_lock(&wifi_mutex);
  CFMutableDictionaryRef store = wifi_load_store_locked();
  if (store != NULL) {
    if (account == NULL) {
      removed = CFDictionaryGetCount(store) != 0;
      CFDictionaryRemoveAllValues(store);
    } else if (CFDictionaryContainsKey(store, account)) {
      removed = true;
      CFDictionaryRemoveValue(store, account);
    }
    write_succeeded = !removed || wifi_write_store_locked(store);
    CFRelease(store);
  }
  pthread_mutex_unlock(&wifi_mutex);

#ifndef USBLITER8_TESTING
  OSStatus real_status = SecItemDelete(query);
  if (!removed) {
    return real_status;
  }
#endif
  if (!removed) {
    return errSecItemNotFound;
  }
  return write_succeeded ? errSecSuccess : errSecNotAvailable;
}

__attribute__((constructor)) static void wifi_shim_loaded(void) {
  ul8_log(WIFI_COMPONENT, "24A435 AirPort credential shim loaded");
}

#ifdef USBLITER8_TESTING
__attribute__((visibility("default"))) int usbliter8_wifi_test_anchor(void) {
  return 1;
}
#endif

UL8_INTERPOSE(ul8_wifi_SecItemCopyMatching, SecItemCopyMatching);
UL8_INTERPOSE(ul8_wifi_SecItemAdd, SecItemAdd);
UL8_INTERPOSE(ul8_wifi_SecItemUpdate, SecItemUpdate);
UL8_INTERPOSE(ul8_wifi_SecItemDelete, SecItemDelete);
