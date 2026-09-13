#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

extern int usbliter8_pairing_test_anchor(void);

int main(void) {
  assert(usbliter8_pairing_test_anchor() == 1);

  char directory[] = "/tmp/usbliter8-pairing-interpose.XXXXXX";
  assert(mkdtemp(directory) != NULL);
  char path[1024];
  assert(snprintf(path, sizeof(path), "%s/pairing.der", directory) > 0);
  assert(setenv("USBLITER8_PAIRING_KEY_PATH", path, 1) == 0);

  CFMutableDictionaryRef query = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  assert(query != NULL);
  CFDictionarySetValue(query, kSecClass, kSecClassKey);
  CFDictionarySetValue(query, kSecReturnRef, kCFBooleanTrue);
  CFDictionarySetValue(query, kSecAttrAccessGroup,
                       CFSTR("lockdown-identities"));
  CFDictionarySetValue(query, kSecAttrLabel,
                       CFSTR("com.apple.lockdown.pairingkeypair"));

  CFTypeRef key = NULL;
  assert(SecItemCopyMatching(query, &key) == errSecSuccess);
  assert(key != NULL && CFGetTypeID(key) == SecKeyGetTypeID());
  CFRelease(key);
  assert(access(path, F_OK) == 0);
  assert(SecItemDelete(query) == errSecSuccess);
  assert(access(path, F_OK) != 0);

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

  int bits = 2048;
  CFNumberRef bit_count =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bits);
  assert(bit_count != NULL);
  const void *key_names[] = {kSecAttrKeyType, kSecAttrKeySizeInBits};
  const void *key_values[] = {kSecAttrKeyTypeRSA, bit_count};
  CFDictionaryRef key_parameters = CFDictionaryCreate(
      kCFAllocatorDefault, key_names, key_values, 2,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  assert(key_parameters != NULL);
  CFErrorRef key_error = NULL;
  SecKeyRef unrelated_key = SecKeyCreateRandomKey(key_parameters, &key_error);
  assert(unrelated_key != NULL && key_error == NULL);
  CFRelease(unrelated_key);

  CFMutableDictionaryRef target_parameters =
      CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, key_parameters);
  assert(target_parameters != NULL);
  CFDictionarySetValue(target_parameters, kSecClass, kSecClassKey);
  CFDictionarySetValue(target_parameters, kSecAttrAccessGroup,
                       CFSTR("lockdown-identities"));
  CFDictionarySetValue(target_parameters, kSecAttrLabel,
                       CFSTR("com.apple.lockdown.pairingkeypair"));
  SecKeyRef replacement_key =
      SecKeyCreateRandomKey(target_parameters, &key_error);
  assert(replacement_key != NULL && key_error == NULL);

  CFMutableDictionaryRef add_item = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  assert(add_item != NULL);
  CFDictionarySetValue(add_item, kSecAttrAccessGroup,
                       CFSTR("lockdown-identities"));
  CFDictionarySetValue(add_item, kSecAttrLabel,
                       CFSTR("com.apple.lockdown.pairingkeypair"));
  CFDictionarySetValue(add_item, kSecValueRef, replacement_key);
  assert(SecItemAdd(add_item, NULL) == errSecSuccess);
  assert(access(path, F_OK) == 0);
  assert(SecItemDelete(query) == errSecSuccess);

  CFRelease(add_item);
  CFRelease(replacement_key);
  CFRelease(target_parameters);
  CFRelease(key_parameters);
  CFRelease(bit_count);
  CFRelease(unrelated);

  CFRelease(query);
  assert(rmdir(directory) == 0);
  puts("pairing interpose test passed");
  return 0;
}
