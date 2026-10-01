// LWS TLS hostname verification (native, real FFI): the monero_c epee `user_ca`
// hostname fix (patch 0017).
//
// LWS on Android trusts a bundled CA set (via Wallet_setCaFilePath), which puts
// the native TLS layer into `user_ca` mode. Before the fix, epee ran the RFC 2818
// hostname check only in `system_ca` mode, so any CA-signed cert for ANY host was
// accepted for the target host -- an on-path attacker could MITM the LWS
// connection and capture the account's private view key.
//
// The bug is Android-only in *production* only because production calls
// setCaFilePath only on Android. The vulnerable/fixed C++ (lwsf + epee) has no OS
// gate (lwsf/src/wallet.cpp selects user_ca purely from "is a CA file set?"), so
// this test reproduces the path on the Linux host by calling setCaFilePath
// directly, then driving a real LWS connect at a local TLS server:
//
//   wrong-host cert + patched .so   -> handshake REJECTED  (server sees nothing)
//   wrong-host cert + UNPATCHED .so -> handshake COMPLETES (the bug -> FAIL)
//   matching-host cert + patched    -> handshake COMPLETES (no over-rejection)
//
// The signal is whether the *server* completes a TLS handshake (message- and
// SDK-independent): a rejected client aborts before the server emits a socket.
//
// Runs in wallet-core's existing `native.yml` job, which builds the real .so and
// sets MONERO_LIB_PATH. It self-skips when the lib is absent, or when `mitm.test`
// does not resolve to loopback (native.yml adds `127.0.0.1 mitm.test` to
// /etc/hosts; a routable NAME is required because a bare IP is treated as local
// and stays plaintext, so no handshake runs).
//
// ignore_for_file: deprecated_member_use

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:monero/monero.dart' as monero;
import 'package:polyseed/polyseed.dart';

const _host = 'mitm.test';

bool get _required => Platform.environment['REQUIRE_MONERO_FFI'] == '1';
String? get _libPath => Platform.environment['MONERO_LIB_PATH'];

/// Points the library at the host build and returns whether it loads.
bool _libAvailable() {
  final override = _libPath;
  if (override != null && override.isNotEmpty) monero.libPath = override;
  try {
    monero.WalletManagerFactory_getLWSFWalletManager();
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> _resolvesToLoopback(String host) async {
  try {
    final addrs = await InternetAddress.lookup(host);
    return addrs.any((a) => a.address == '127.0.0.1');
  } catch (_) {
    return false;
  }
}

/// A loopback TLS server presenting (cert, key). [sawHandshake] flips true only
/// when a client completes the TLS handshake (SecureServerSocket emits a socket
/// post-handshake); a rejected client never gets that far.
class _TlsServer {
  _TlsServer(this._socket);
  final SecureServerSocket _socket;
  bool sawHandshake = false;
  int get port => _socket.port;
  Future<void> close() => _socket.close();

  static Future<_TlsServer> start(String certPem, String keyPem) async {
    final ctx = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(certPem))
      ..usePrivateKeyBytes(utf8.encode(keyPem));
    // Dual-stack: a routable test name resolves to both ::1 and 127.0.0.1, and
    // the native client may try IPv6 first, so an IPv4-only listener would be
    // refused before the handshake even runs.
    final socket = await SecureServerSocket.bind(InternetAddress.anyIPv6, 0, ctx);
    final server = _TlsServer(socket);
    socket.listen(
      (client) {
        server.sawHandshake = true;
        client.destroy();
      },
      onError: (_) {}, // a rejected client handshake surfaces here; ignore it
    );
    return server;
  }
}

/// Runs the real LWS connect entirely in a spawned isolate, so the main event
/// loop stays free to drive [_TlsServer]. libPath is re-set here because a fresh
/// isolate does not inherit the main isolate's top-level override.
Future<Map<String, Object?>> _lwsConnect({
  required String libPath,
  required String walletPath,
  required String mnemonic,
  required String caFilePath,
  required String daemonAddress,
}) {
  return Isolate.run(() {
    monero.libPath = libPath;
    final wm = monero.WalletManagerFactory_getLWSFWalletManager();
    final wallet = monero.WalletManager_createWalletFromPolyseed(
      wm,
      path: walletPath,
      password: 'fixture-test',
      networkType: 0,
      mnemonic: mnemonic,
      seedOffset: '',
      newWallet: true,
      restoreHeight: 0,
      kdfRounds: 1,
    );
    final createErr = monero.Wallet_errorString(wallet);
    if (createErr.isNotEmpty) return {'stage': 'create', 'error': createErr};

    // Force user_ca: trust this CA file. This is the exact call production makes
    // only on Android; the C++ path it triggers is platform-independent.
    monero.Wallet_setCaFilePath(wallet, caFilePath);
    monero.Wallet_init(
      wallet,
      daemonAddress: daemonAddress,
      proxyAddress: '',
      useSsl: true,
      lightWallet: true,
    );
    monero.Wallet_connectToDaemon(wallet);
    return {
      'stage': 'connect',
      'connected': monero.Wallet_connected(wallet),
      'error': monero.Wallet_errorString(wallet),
    };
  });
}

String _freshSeed() => Polyseed.create()
    .encode(PolyseedLang.getByEnglishName('English'), PolyseedCoin.POLYSEED_MONERO);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('lws_tls_mitm'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Skips (or fails, under REQUIRE_MONERO_FFI) when the prerequisites are
  /// missing; returns true when the test can run for real.
  Future<bool> ready() async {
    if (!_libAvailable()) {
      if (_required) {
        fail('REQUIRE_MONERO_FFI=1 but monero_c did not load (libPath='
            '"${monero.libPath}"). Build it with scripts/build-moneroc-ci.sh '
            'and set MONERO_LIB_PATH.');
      }
      markTestSkipped('needs a monero_c build; set MONERO_LIB_PATH');
      return false;
    }
    if (!await _resolvesToLoopback(_host)) {
      if (_required) {
        fail('REQUIRE_MONERO_FFI=1 but "$_host" does not resolve to 127.0.0.1. '
            'Add `127.0.0.1 $_host` to /etc/hosts (native.yml does this).');
      }
      markTestSkipped('"$_host" must resolve to 127.0.0.1 (add it to /etc/hosts)');
      return false;
    }
    return true;
  }

  test('user_ca rejects a CA-trusted cert issued for the wrong host', () async {
    if (!await ready()) return;

    final server = await _TlsServer.start(_wrongHostCert, _wrongHostKey);
    addTearDown(server.close);
    final ca = '${tmp.path}/ca.pem';
    File(ca).writeAsStringSync(_wrongHostCert); // trusted as a root -> chain is valid

    final result = await _lwsConnect(
      libPath: _libPath!,
      walletPath: '${tmp.path}/wallet',
      mnemonic: _freshSeed(),
      caFilePath: ca,
      daemonAddress: 'https://$_host:${server.port}',
    ).timeout(const Duration(seconds: 60));
    await Future<void>.delayed(const Duration(milliseconds: 300)); // let accept settle

    expect(
      server.sawHandshake,
      isFalse,
      reason: 'The cert is for wrong.host but we connect as $_host, so the patched '
          '.so must reject it at the TLS handshake. A completed handshake means '
          'patch 0017 is missing (the user_ca hostname bug). connect: $result',
    );
  });

  test('user_ca accepts a CA-trusted cert issued for the matching host', () async {
    if (!await ready()) return;

    final server = await _TlsServer.start(_matchCert, _matchKey);
    addTearDown(server.close);
    final ca = '${tmp.path}/ca.pem';
    File(ca).writeAsStringSync(_matchCert);

    final result = await _lwsConnect(
      libPath: _libPath!,
      walletPath: '${tmp.path}/wallet',
      mnemonic: _freshSeed(),
      caFilePath: ca,
      daemonAddress: 'https://$_host:${server.port}',
    ).timeout(const Duration(seconds: 60));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      server.sawHandshake,
      isTrue,
      reason: 'The cert matches $_host, so the handshake must complete (the fix '
          'must not over-reject). connect: $result',
    );
  });
}

// Self-signed, SAN=DNS:mitm.test (matches the host we connect to), ~100 years.
const _matchCert = '''
-----BEGIN CERTIFICATE-----
MIIDITCCAgmgAwIBAgIUL/yQa5HIaKbXCLK0y4kwJT8ptjgwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbWl0bS50ZXN0MCAXDTI2MDkzMDE5NDEzOFoYDzIxMjYw
OTA2MTk0MTM4WjAUMRIwEAYDVQQDDAltaXRtLnRlc3QwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQDerYtQdXjhBbzjUZciLYfm2TpZhS/eZ28ALCmFc/2c
KN1cJTBtprr2FDl+oLjHxbmweOt8kh7L5oGt7oTSHreE64mMlAkEfkD6lixQ32D5
HJhN2REXwa70BC3oc98U2yGJ0/v1WhQlKw5EHr4p07cHyc3Ch62MbssdkfXAwVgQ
POO2pY+6VBqwLLBws/VaIxlft4AGovZyIM4nDCi/Hh90Nr7ng8c+uUx+DvdRgpX5
01Of95q171VUyrKFIuICLrKULAwbm1F6FGmT0M293Dw8WNU4gjboYtw23sa5xMuc
fCwVu1yNMJdUTlZpeRmDfogQYCIU4KhGH9Sp9lkGyhItAgMBAAGjaTBnMB0GA1Ud
DgQWBBQnmd4WNqmr4/auUfrFq9hNg3C5vjAfBgNVHSMEGDAWgBQnmd4WNqmr4/au
UfrFq9hNg3C5vjAPBgNVHRMBAf8EBTADAQH/MBQGA1UdEQQNMAuCCW1pdG0udGVz
dDANBgkqhkiG9w0BAQsFAAOCAQEAForM/ZHd6zOvdiOmFCfKYBvdcNBSMV5gtVI/
/WpMRLXQ01jkQgHD5rH7/fq1PzoEMOpUQ7TD3m9Mb/4QVTeVbGbfIsqgcCQdvPyP
E54FkQp9j7BlXZsGM95rIFJGoAwtwvCcmfgKIdY2gx6gBeCqwjMOPizN4hjx60cX
+JOTxBIlUnhhwWfnPiLun3Cih0Cf7wvBQdGL5q7hs2V0ALOzhCqkNGpm59w2xuKc
PzYRM4y8/Mt/93k8n9qIMsql6JIzL91yXUcYflE6pkALox7+IK/bjjYUKTsQwyf9
NtDCvHed3yGv1b8Me4HeE4KCmemxgRgeXHTPAItwJq/UF7025g==
-----END CERTIFICATE-----
''';

const _matchKey = '''
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDerYtQdXjhBbzj
UZciLYfm2TpZhS/eZ28ALCmFc/2cKN1cJTBtprr2FDl+oLjHxbmweOt8kh7L5oGt
7oTSHreE64mMlAkEfkD6lixQ32D5HJhN2REXwa70BC3oc98U2yGJ0/v1WhQlKw5E
Hr4p07cHyc3Ch62MbssdkfXAwVgQPOO2pY+6VBqwLLBws/VaIxlft4AGovZyIM4n
DCi/Hh90Nr7ng8c+uUx+DvdRgpX501Of95q171VUyrKFIuICLrKULAwbm1F6FGmT
0M293Dw8WNU4gjboYtw23sa5xMucfCwVu1yNMJdUTlZpeRmDfogQYCIU4KhGH9Sp
9lkGyhItAgMBAAECggEABJxffpbCVyVeE0SVNLK3mbX2n7P4AEAh++iRvvmXPWgg
4Q3SoyPyCivJbRjXe4wnxGnVA5FLVVfovayAfmZUQqcVkj4zsplexQUeMqEN6/Yl
wYh2eZ3RKUj0F2ZdRCNfVwy+WX/C6jFU9Sb5CMjaTHRnJVXXfVCDNh/0EKwuceIJ
OFY1GdFVTZCAokPxNJyhPas+pviTqegfFtJ/wvGMGuGCXwrvMUW+Krqd4/MQvcaa
KIFiUqGwahGBJ1HGjV1eZAKynNGWzw2IVXgqkmR8QBA2F2eoBb/bqGjOoL+3GWHO
YXk9ubk9RYOnJASrZNdcIZForjHlfBFd3tc1UiBbeQKBgQDvJ9SXJGm1UWp+o0MB
lb3hcDWIYvoQ2ClRnk1P7+A5VYkpgb6u04AkynPdvqIyn6KI6GUvFPEwy4JlfCP+
H0w4kpCw54Y3naZHY/sT88kp5wyhkzSBeKJyJY3clQJebGkl5oen/QKFmOI6q4Ab
8HVazsPdFM0WcjFhI8HrUoan+QKBgQDuXJuYda4G5eH1wGZTR+CLDpxtbhJzg8Hh
QEsd5ZXfdRVS2Ph+gZx1QbwnURloUuOZrLN1/w1iEL3QDCMukHHjwBO7a8zbPBa3
fZV2Zk5KXjlIFjmrDBhKB+v3JPui6GVG/rOo78Sdvp9i0x8JCbR2qLbpOti8QQzZ
05Efo/bQ1QKBgQDH4SxG3kITLuaozN7V1kcKwfOb9800gtWVx46qPrvSb3Dh5fRu
vYoeNa69J/T8BnubnU/kF8a1l4F2PFkArTvRFH4lvHtqxDIS/Lb+KAR7JwZhjFyX
0TFD4as9LrT6IfWHnbLHbijLa8m4a1n4//G1YZZFknsORYaLv4z1ltXAUQKBgGLZ
/yFENI7hyUrspsME/QdOYOs1CevkCYTL8BsO+o+4c8Zu+uckA2nRgCFiDcJpFcDG
kYpu4vL3dHCSiAiomMLWBpjkhQmqqtUf/NskZHWNC/5sUTAxjOUu0dol+UG/VTkT
Khj2jrjItDr8yVMrNi87mtewsu+nnpe7mOThT9udAoGBAICgmIDyZuWu/3LDtXVa
+DcNNwMFa6zJocbq1JNEQbzA1AWHtcnCS+iOrpskJDDF6kVvEIoBF5hxYZaAPi2R
hFgnPCPHBhAHH2FPter7RH55SpJWRooX6WoNMvTmKK8xeBVLF8Ka3ysV9YYS4QTE
1PGBt9tdLtVVE+Fz1FD2vFj3
-----END PRIVATE KEY-----
''';

// Self-signed, SAN=DNS:wrong.host (the MITM cert), valid ~100 years.
const _wrongHostCert = '''
-----BEGIN CERTIFICATE-----
MIIDJDCCAgygAwIBAgIURQvYavZUvp2IOONSM4jdClO68B0wDQYJKoZIhvcNAQEL
BQAwFTETMBEGA1UEAwwKd3JvbmcuaG9zdDAgFw0yNjA5MzAxODQ5MzdaGA8yMTI2
MDkwNjE4NDkzN1owFTETMBEGA1UEAwwKd3JvbmcuaG9zdDCCASIwDQYJKoZIhvcN
AQEBBQADggEPADCCAQoCggEBANw3s42Bz6EJpY9BwzmLZEgIyBZaQibHQXVks2Y8
yb+pb+N/evv04sWSKrH6ltBf6uBiPSNKGuAWUv3yuoOt/vVwzQQQY/H6/3Gr8z9W
lwwC6JgKIRh1yAHuVuzTawnqaZ4XJHUqCieQ5TUP59mxVq/lxPFW+1mhEIhdz+xW
uYwcKcRB3+zhTTeNYAKMGtQw6Cf/6dB/dLChzzeAICQKh8HNk9lME3gYAH3q8HLK
r4bDdOOG6P8C5g8HvkotYikxE6Jup4yyRIM8RbgMgB7MGMb99q2HatgeckTMh1yt
gXIYbPYasL6uUilyG7A9uovGu4gcqgLPm8AupZfacu/JZGECAwEAAaNqMGgwHQYD
VR0OBBYEFM6uZlh9j0LH/dwSBR1yDDbpvZgYMB8GA1UdIwQYMBaAFM6uZlh9j0LH
/dwSBR1yDDbpvZgYMA8GA1UdEwEB/wQFMAMBAf8wFQYDVR0RBA4wDIIKd3Jvbmcu
aG9zdDANBgkqhkiG9w0BAQsFAAOCAQEAjiKyjBzzqhnPEuIXFklRXmomBYNNWsIi
9bEB1zHDh4dUWhrDdoo5H89fqgyjZ6B25xv0GPbYEYOTYppqVLTIwzxhqBFerPEp
+UVKnoGyVs992mqhbWrRgoAs59FyhzmiVz+ZAtdYzApnfUoRqCpX0fakODXrhjWC
FdjpO4VKiCtOO7zoarL0EQJmLXda8KIVNys8vwwP80RjkyUpq/MJ5bdautPXH+pf
+gUUpx5eMjJZ46aHpxdQrYPZi0blW+X186poG3pgU7yGnIVFg8Ktn+6TrWOImkug
0jFyRLsVb/oVB/6MAdWcEcHjHu/Ghl58cls9p2BDRiAlH1MyX3EZOA==
-----END CERTIFICATE-----
''';

const _wrongHostKey = '''
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDcN7ONgc+hCaWP
QcM5i2RICMgWWkImx0F1ZLNmPMm/qW/jf3r79OLFkiqx+pbQX+rgYj0jShrgFlL9
8rqDrf71cM0EEGPx+v9xq/M/VpcMAuiYCiEYdcgB7lbs02sJ6mmeFyR1KgonkOU1
D+fZsVav5cTxVvtZoRCIXc/sVrmMHCnEQd/s4U03jWACjBrUMOgn/+nQf3Swoc83
gCAkCofBzZPZTBN4GAB96vByyq+Gw3Tjhuj/AuYPB75KLWIpMROibqeMskSDPEW4
DIAezBjG/fath2rYHnJEzIdcrYFyGGz2GrC+rlIpchuwPbqLxruIHKoCz5vALqWX
2nLvyWRhAgMBAAECggEAKkU/4Cj7dZYgMyokouJUhrY20AGVwpNLR5EjlXuUH0fT
DBhff0cPk2x96QlokwliUJ1SzngORhbK6eeCcT3AG5VCKSZLRPrQtx1SNQV2O25A
ftSs6yDKmkJJaa6gVHgsO1YGX74I0nTv5jpOHv15Hgzs+4VefGMcBQz62QsBlTjE
Ug/vdygiL5+gcTZJPvsfwluuiOWEn0/hqXBmpi/0UlC1s3rSJUHPLIXs6bgb4gni
aVUtupx25A+XxlPZQeJONUHCXDzH9IVqlrfthzQD5Umd+8HuQ4I5MGjmIXYE5CFu
pBZ618hTNo/kpeWt6pt0SDIveeMykEf4XwcophE7tQKBgQD/BCtNhw533F1uTowY
rB+b4wRPvGGmnYynQFHu5YnjeTGi7xSj9Nl3HAlNhC0mVJR0KEhk4TSYHEL8EQrM
59H+c9RG6fGuyVPNBZD9Jj5vk4dkS9ZyLiCEl5TtFzremdrPfIQH1U9d+6qGTlwX
x5cuGTke8uCUdlf/v2f1o4HbVQKBgQDdESsPD5z4QGKEn9qTPNKB+AUKm7qWXUTj
UWLoXQKopKwzVYCOaGC92TZ2W3FJmUhDddVCOMatn8VRCtIYrVU2BqQc1tiIeNs3
WFDNQF5DbcQhharDnMUHycwWN4FAI2RxXEglK2IouFyx8WeJ4eebUa/gL3z6Ghnz
8cMg42rc3QKBgQClbfzxVBWMp8VsU0QKlU4EACbB2wC15yphLRZ5lSn4CJysh8+p
9KJF5Egcowvu+5s6Jw+fcYB+1IaXoi6RcikFmfow7n471pqoO14s+mwyUU/ZPmEk
vMuXeAXCL/megcwyISI9OqE75JBgg+C2BGIMI4ysiP4rEQJRA8faz3Dj6QKBgQCV
C/A2FVbF4dMKjCR4RPfA/RGZF2nz2yqJAORoud0DCxO3AJzOZv1iwsJ/hiOZdalN
InMIVPNPOHt2qo8AaE0dQdkAQLJ5QNK8O+UunYlweN9VoqOBg38sQxhAmmegcLxV
2dwig1+JCNQmfRZL1m2rQKYNxrbCgTqiSIxA7lOsWQKBgG3eL05wg+S+42FfSbtk
Vv+AX26zt/pleijg4S3tst++ukIL6BmSxZSN9RbHRrPWw94hO9BNYoSlf22cfj0l
Wi63TNIJuLbg8OQ8AOueNpHOnClvOWpVTU8BtvNVXO0Oeual+VNyAO1UFiyUFXUz
rh4hhh2Gk/UJGJbuVuz02Wwf
-----END PRIVATE KEY-----
''';
