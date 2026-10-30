// The structs lib/src/backends/webauthn_bindings.dart binds, laid out by clang
// for Windows. windows_webauthn_layout_test.dart compares Dart's layout with
// the dumps next to this file.
//
// webauthn.h is Microsoft's (github.com/microsoft/webauthn, MIT), commit
// 0ef86c2fe31e5b0608cc4fce4820935bd644cabb (API version 9), blob b5eaca30f1ca.
// It is not checked in. To regenerate the dumps, put it in a directory with
// two empty files, winapifamily.h and guiddef.h, and run for each target
// (x86_64-pc-windows-msvc, aarch64-pc-windows-msvc):
//
//   clang -target <target> -fsyntax-only -Xclang -fdump-record-layouts \
//     -I <that directory> layouts.c > <target>.txt

// The Windows types webauthn.h uses. On Windows, long is 32-bit (LLP64) and
// wchar_t is 16-bit; the asserts hold the stub to that.
typedef unsigned long DWORD;
typedef long LONG;
typedef int BOOL;
typedef unsigned short WORD;
typedef unsigned char BYTE, *PBYTE;
typedef __WCHAR_TYPE__ WCHAR; // wchar_t, as <stddef.h> defines it.
typedef const WCHAR *PCWSTR, *LPCWSTR;
typedef void *PVOID;
typedef long HRESULT;
typedef struct HWND__ *HWND;
typedef struct _GUID {
  unsigned long Data1;
  unsigned short Data2;
  unsigned short Data3;
  unsigned char Data4[8];
} GUID;

_Static_assert(sizeof(DWORD) == 4, "DWORD is 32-bit on Windows");
_Static_assert(sizeof(WCHAR) == 2, "WCHAR is 16-bit on Windows");
_Static_assert(sizeof(PVOID) == 8, "64-bit target");

#define WINAPI_FAMILY_PARTITION(x) 1
#define WINAPI_PARTITION_APP 1
#define WINAPI_PARTITION_SYSTEM 2
#define _Field_size_(x)
#define _Field_size_bytes_(x)
#define _In_
#define _In_opt_
#define _Out_
#define _Outptr_result_maybenull_
#define _In_reads_bytes_(x)

#include "webauthn.h"

// sizeof makes clang lay out, and so dump, each struct.
unsigned long long layouts[] = {
    sizeof(GUID),
    sizeof(WEBAUTHN_RP_ENTITY_INFORMATION),
    sizeof(WEBAUTHN_USER_ENTITY_INFORMATION),
    sizeof(WEBAUTHN_CLIENT_DATA),
    sizeof(WEBAUTHN_COSE_CREDENTIAL_PARAMETER),
    sizeof(WEBAUTHN_COSE_CREDENTIAL_PARAMETERS),
    sizeof(WEBAUTHN_CREDENTIAL),
    sizeof(WEBAUTHN_CREDENTIALS),
    sizeof(WEBAUTHN_CREDENTIAL_EX),
    sizeof(WEBAUTHN_CREDENTIAL_LIST),
    sizeof(WEBAUTHN_HMAC_SECRET_SALT),
    sizeof(WEBAUTHN_HMAC_SECRET_SALT_VALUES),
    sizeof(WEBAUTHN_CRED_PROTECT_EXTENSION_IN),
    sizeof(WEBAUTHN_EXTENSION),
    sizeof(WEBAUTHN_EXTENSIONS),
    sizeof(WEBAUTHN_AUTHENTICATOR_MAKE_CREDENTIAL_OPTIONS),
    sizeof(WEBAUTHN_AUTHENTICATOR_GET_ASSERTION_OPTIONS),
    sizeof(WEBAUTHN_CREDENTIAL_ATTESTATION),
    sizeof(WEBAUTHN_ASSERTION),
};
