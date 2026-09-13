#define USBLITER8_TESTING 1
#include "wifi_keychain_shim.c"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static CFMutableDictionaryRef make_airport_query(CFStringRef account,
                                                 bool return_data,
                                                 bool return_attributes) {
  CFMutableDictionaryRef query = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  assert(query != NULL);
  CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
  CFDictionarySetValue(query, kSecAttrService, CFSTR("AirPort"));
  CFDictionarySetValue(query, kSecAttrAccount, account);
  if (return_data) {
    CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
  }
  if (return_attributes) {
    CFDictionarySetValue(query, kSecReturnAttributes, kCFBooleanTrue);
  }
  return query;
}

static CFDataRef password_data(const char *password) {
  return CFDataCreate(kCFAllocatorDefault, (const UInt8 *)password,
                      (CFIndex)strlen(password));
}

int main(void) {
  char directory[] = "/tmp/usbliter8-wifi-test.XXXXXX";
  assert(mkdtemp(directory) != NULL);

  char path[1024];
  assert(snprintf(path, sizeof(path), "%s/wifi.plist", directory) > 0);
  assert(setenv("USBLITER8_WIFI_PASSWORD_PATH", path, 1) == 0);

  CFMutableDictionaryRef query =
      make_airport_query(CFSTR("Test Network"), true, false);
  CFDataRef first_password = password_data("first-password");
  CFDictionarySetValue(query, kSecValueData, first_password);
  assert(ul8_wifi_SecItemAdd(query, NULL) == errSecSuccess);

  struct stat attributes;
  assert(stat(path, &attributes) == 0);
  assert((attributes.st_mode & 0777) == 0600);

  CFDictionaryRemoveValue(query, kSecValueData);
  CFTypeRef copied = NULL;
  assert(ul8_wifi_SecItemCopyMatching(query, &copied) == errSecSuccess);
  assert(copied != NULL && CFGetTypeID(copied) == CFDataGetTypeID());
  assert(CFEqual(copied, first_password));
  CFRelease(copied);

  CFDataRef second_password = password_data("second-password");
  CFMutableDictionaryRef update = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  assert(update != NULL);
  CFDictionarySetValue(update, kSecValueData, second_password);
  assert(ul8_wifi_SecItemUpdate(query, update) == errSecSuccess);

  copied = NULL;
  assert(ul8_wifi_SecItemCopyMatching(query, &copied) == errSecSuccess);
  assert(CFEqual(copied, second_password));
  CFRelease(copied);

  CFDictionarySetValue(query, kSecReturnAttributes, kCFBooleanTrue);
  copied = NULL;
  assert(ul8_wifi_SecItemCopyMatching(query, &copied) == errSecSuccess);
  assert(copied != NULL && CFGetTypeID(copied) == CFDictionaryGetTypeID());
  assert(CFEqual(CFDictionaryGetValue((CFDictionaryRef)copied, kSecClass),
                 kSecClassGenericPassword));
  assert(CFEqual(CFDictionaryGetValue((CFDictionaryRef)copied, kSecValueData),
                 second_password));
  CFRelease(copied);

  assert(ul8_wifi_SecItemDelete(query) == errSecSuccess);
  copied = NULL;
  assert(ul8_wifi_SecItemCopyMatching(query, &copied) == errSecItemNotFound);
  assert(copied == NULL);

  CFRelease(update);
  CFRelease(second_password);
  CFRelease(first_password);
  CFRelease(query);

  assert(unlink(path) == 0);
  assert(rmdir(directory) == 0);
  puts("wifi shim tests passed");
  return 0;
}
