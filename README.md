# wallet-core

Shared wallet packages for
[Skylight Wallet](https://github.com/MAGICGrants/skylight-wallet) (Monero-only)
and [Spice Wallet](https://github.com/MAGICGrants/spice-wallet) (multi-coin).

This repo contains the shared components for both apps, which makes maintenance
easier. Each app only pulls the specific pieces that they need.

## Packages

```
packages/
  wallet_infra/      transport, storage, logging, at-rest crypto (no coin or app knowledge)
  wallet_domain/     CryptoWallet, WalletManager, seeds, stores, alias policy
  wallet_monero/     Monero: light-wallet server and full node; polyseed, BIP39, 25-word
  wallet_bitcoin/    Bitcoin and testnet: BIP84 over Electrum
  wallet_ethereum/   Ethereum, Sepolia and ERC-20: JSON-RPC plus Blockscout history
  wallet_openalias/  OpenAlias resolution over Tor, DNSSEC-validated (Rust FFI)
  wallet_background/ background sync and incoming-transaction notifications
  wallet_fiat/       fiat exchange rates from Kraken
  wallet_ui/         shared Flutter widgets
scripts/             reproducible-build tooling for monero_c and the Tor toolchain
Dockerfile.builder   pinned build image
test_fixtures/       manifest for the generated Monero test wallets
```

One package per capability, so an app compiles only what it uses.

Alias resolution is split in two. `wallet_domain` holds the policy: bounds,
sanitization, per-coin address validation, and a Tor gate that fails closed.
`wallet_openalias` holds the resolver, which is a Rust build and would otherwise
drag a Rust toolchain into every consumer. `AliasResolver` is the seam; the app
installs `resolveOpenAlias` in `main()`.

Logging is a privacy surface. Seeds, keys and raw server payloads never reach a
log; addresses and transaction ids only as salted fingerprints; amounts only as
an order of magnitude. `Redact` in `wallet_infra` is the toolkit.

## Getting started

Requires Flutter 3.41.7. The packages form a Dart pub workspace, so one command
at the root resolves all of them.

```bash
flutter pub get
flutter analyze
dart format packages/*/lib packages/*/test packages/*/tool
```

Run the tests for one package from its own directory:

```bash
cd packages/wallet_domain && flutter test
```

Format the three directories listed above rather than `.`. `dart format` reads
`page_width` from `analysis_options.yaml` but ignores its `exclude:`, so `.`
rewrites the vendored cargokit build tool under `wallet_openalias`.

### Working on an app and the core together

Add a gitignored `pubspec_overrides.yaml` to the app repo, pointing at your
local clone:

```yaml
dependency_overrides:
  wallet_infra:
    path: ../wallet-core/packages/wallet_infra
  wallet_domain:
    path: ../wallet-core/packages/wallet_domain
  wallet_monero:
    path: ../wallet-core/packages/wallet_monero
  wallet_openalias:
    path: ../wallet-core/packages/wallet_openalias
  # Plus every override from the app's own pubspec.yaml, copied verbatim:
  # hashlib, bip39, blockchain_utils, web3dart, intl. See the table below.
```

**`pubspec_overrides.yaml` replaces `pubspec.yaml`'s `dependency_overrides`
rather than merging with them**, so it has to restate every override the app
already declares, not just the paths. Dropping one usually fails at resolution;
dropping `hashlib` is worse, because it resolves fine and then fails as a
compile error inside `polyseed`.

### Consuming from an app

These packages are not published, so an app depends on them by git SHA with a
`path:` into the repo.

```yaml
  wallet_monero:
    git:
      url: https://github.com/MAGICGrants/wallet-core
      ref: <sha>
      path: packages/wallet_monero
```

Apps must repeat this repo's `dependency_overrides` in their own `pubspec.yaml`.
Pub honours overrides only in the package it resolves from, so the ones here
apply when you run `flutter pub get` in this repo and nowhere else. Which ones
you need depends on the packages you take:

| Override | Needed when you depend on |
| --- | --- |
| `hashlib: 1.19.2` | `wallet_domain` or `wallet_monero` (both pull `polyseed`) |
| `bip39` at the `cypherstack/stack-bip39` SHA | any coin package or `wallet_domain` |
| `blockchain_utils` at the `cake-tech` SHA | `wallet_bitcoin`, `wallet_ethereum` or `wallet_monero` |
| `web3dart` at the `cake-tech` SHA | `wallet_ethereum` |
| `intl: any` | you also use `flutter_localizations` |

Copy the values from the root `pubspec.yaml`.

## Pins and reproducible builds

Everything is pinned to a commit to make builds verifiable.

- `monero_c`: `magicgrants/monero_c@757bf8e`, a fork carrying
  `Wallet_estimateTransactionFee`.
- `tor_ffi_plugin`: `cypherstack/tor@c2706ee`.
- `bip39`: `cypherstack/stack-bip39@0cd6d54`, which fixes an entropy bug
  upstream still has.

`scripts/` holds the build tooling, since this repo owns the pins. Apps get it
as a git submodule. The F-Droid recipe already sets `submodules: true`, so
nothing changes there, and F-Droid still builds monero_c from source.

Two of the scripts look odd:

- `pin-tor-rust-toolchain.sh` patches cargokit after it is fetched. cargokit
  hardcodes `rustup run stable`, a channel that moves over time, and its config
  accepts only a channel name rather than an exact version, so patching the
  fetched package is the only way to fix the compiler version.
- `fix-linux-moneroc-execstack.sh` clears the executable-stack flag on the Linux
  monero_c library. Without it, hardened kernels refuse to load the library.

## Monero test wallets

Ten prebuilt wallets that pin the seed-to-address derivation. Each is a real
wallet directory in one state (restored from a polyseed, from a 25-word seed,
node mode, a corrupt cache) plus the answer the code should give for it. A
changed address means the derivation changed, which is otherwise silent: the
wallet still opens, it just belongs to someone else.

Generated rather than committed; only the manifest is tracked. The seeds are
published and the wallets are stagenet, so none can hold real value.

```bash
cd packages/wallet_monero
dart run tool/make_fixtures.dart            # generate
dart run tool/make_fixtures.dart --verify   # check against the tracked manifest
```

Seven of the ten need a real Monero library, so set `MONERO_LIB_PATH` to the
built `libwallet2_api_c`. Without it the generator builds only the three that
need no FFI, and **rewrites the tracked manifest without the rest**. CI is a
fresh checkout, so that is harmless there. Locally, run `git checkout --
test_fixtures/wallets/MANIFEST.json` afterwards and do not commit it.

Recorded addresses are cross-checked against a second, independent Monero
implementation, so this does not just check monero_c against itself.

## CI

`ci.yml` runs on every push: analysis, formatting and the unit tests for every
package, plus `cargo test` for the OpenAlias resolver and a native-crypto job.
Everything there uses `FakeMoneroBackend` rather than a real Monero library.

`native.yml` builds monero_c and runs `wallet_monero`'s tests against it,
generating the test wallets on the way. It runs nightly rather than per-push,
because building Monero from source takes tens of minutes. So between nightly
runs a change to `wallet_monero` has only been tested against the fake.

`build-monero-c.yml` is manual (`workflow_dispatch`). It builds the library for
each target and uploads it as an artifact. Use it when you want a library to
develop against locally.
