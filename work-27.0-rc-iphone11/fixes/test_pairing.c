#define USBLITER8_TESTING 1
#include "pairing_key_shim.c"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

static CFMutableDictionaryRef make_pairing_query(void) {
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
  return query;
}

static CFDataRef key_bytes(SecKeyRef key) {
  CFErrorRef error = NULL;
  CFDataRef bytes = SecKeyCopyExternalRepresentation(key, &error);
  assert(error == NULL);
  assert(bytes != NULL);
  return bytes;
}

int main(void) {
  char directory[] = "/tmp/usbliter8-pairing-test.XXXXXX";
  assert(mkdtemp(directory) != NULL);

  char path[1024];
  assert(snprintf(path, sizeof(path), "%s/pairing.der", directory) > 0);
  assert(setenv("USBLITER8_PAIRING_KEY_PATH", path, 1) == 0);

  CFMutableDictionaryRef query = make_pairing_query();
  CFTypeRef first_value = NULL;
  assert(ul8_pair_SecItemCopyMatching(query, &first_value) == errSecSuccess);
  assert(first_value != NULL);
  assert(CFGetTypeID(first_value) == SecKeyGetTypeID());
  CFDataRef first_bytes = key_bytes((SecKeyRef)first_value);

  struct stat attributes;
  assert(stat(path, &attributes) == 0);
  assert((attributes.st_mode & 0777) == 0600);

  CFTypeRef second_value = NULL;
  assert(ul8_pair_SecItemCopyMatching(query, &second_value) == errSecSuccess);
  CFDataRef second_bytes = key_bytes((SecKeyRef)second_value);
  assert(CFEqual(first_bytes, second_bytes));

  assert(ul8_pair_SecItemDelete(query) == errSecSuccess);
  assert(access(path, F_OK) != 0);

  CFTypeRef third_value = NULL;
  assert(ul8_pair_SecItemCopyMatching(query, &third_value) == errSecSuccess);
  CFDataRef third_bytes = key_bytes((SecKeyRef)third_value);
  assert(!CFEqual(first_bytes, third_bytes));

  CFRelease(third_bytes);
  CFRelease(third_value);
  CFRelease(second_bytes);
  CFRelease(second_value);
  CFRelease(first_bytes);
  CFRelease(first_value);
  CFRelease(query);

  assert(unlink(path) == 0);
  assert(rmdir(directory) == 0);
  puts("pairing shim tests passed");
  return 0;
}
