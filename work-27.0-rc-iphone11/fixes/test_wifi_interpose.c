#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int usbliter8_wifi_test_anchor(void);

int main(void) {
  assert(usbliter8_wifi_test_anchor() == 1);

  char directory[] = "/tmp/usbliter8-wifi-interpose.XXXXXX";
  assert(mkdtemp(directory) != NULL);
  char path[1024];
  assert(snprintf(path, sizeof(path), "%s/wifi.plist", directory) > 0);
  assert(setenv("USBLITER8_WIFI_PASSWORD_PATH", path, 1) == 0);

  CFMutableDictionaryRef item = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  assert(item != NULL);
  CFDictionarySetValue(item, kSecClass, kSecClassGenericPassword);
  CFDictionarySetValue(item, kSecAttrService, CFSTR("AirPort"));
  CFDictionarySetValue(item, kSecAttrAccount, CFSTR("Interpose Test"));
  CFDictionarySetValue(item, kSecReturnData, kCFBooleanTrue);

  const char password_text[] = "interpose-password";
  CFDataRef password =
      CFDataCreate(kCFAllocatorDefault, (const UInt8 *)password_text,
                   sizeof(password_text) - 1);
  assert(password != NULL);
  CFDictionarySetValue(item, kSecValueData, password);
  assert(SecItemAdd(item, NULL) == errSecSuccess);

  CFDictionaryRemoveValue(item, kSecValueData);
  CFTypeRef copied = NULL;
  assert(SecItemCopyMatching(item, &copied) == errSecSuccess);
  assert(copied != NULL && CFEqual(copied, password));
  CFRelease(copied);
  assert(SecItemDelete(item) == errSecSuccess);

  CFMutableDictionaryRef unrelated = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  assert(unrelated != NULL);
  CFDictionarySetValue(unrelated, kSecClass, kSecClassGenericPassword);
  CFDictionarySetValue(unrelated, kSecAttrService,
                       CFSTR("com.usbliter8.pass-through-test"));
  CFDictionarySetValue(unrelated, kSecReturnData, kCFBooleanTrue);
  CFTypeRef unrelated_result = NULL;
  (void)SecItemCopyMatching(unrelated, &unrelated_result);
  if (unrelated_result != NULL) {
    CFRelease(unrelated_result);
  }
  CFRelease(unrelated);

  CFRelease(password);
  CFRelease(item);
  assert(unlink(path) == 0);
  assert(rmdir(directory) == 0);
  puts("wifi interpose test passed");
  return 0;
}
