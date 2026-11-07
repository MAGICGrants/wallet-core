import 'dart:io';

import 'package:wallet_domain/wallet_domain.dart';

import '../backup_service.dart';

/// A metadata backup that reports a running backup without keeping one, for
/// store screenshots: the places in [on] switched on and up to date, holding
/// [payments] payments, [contacts] contacts and [labels] address labels as of
/// [lastSync].
///
/// It writes nothing and reads nothing: every call that would touch a backup
/// file, the address book or a wallet's payment records does nothing, so the
/// app runs as it would with backups off.
class SampleMetadataBackupService extends MetadataBackupService {
  SampleMetadataBackupService({
    required super.locations,
    required this.on,
    required this.payments,
    required this.contacts,
    this.labels = 0,
    required this._lastSync,
  }) : super(localRoot: () async => Directory.systemTemp, observeLifecycle: false);

  final Set<String> on;
  final int payments;
  final int contacts;
  final int labels;
  final DateTime _lastSync;

  @override
  BackupAvailability get availability => BackupAvailability.open;

  @override
  bool get isOpen => true;

  @override
  bool get enabled => true;

  @override
  DateTime? get lastSync => _lastSync;

  @override
  int get paymentCount => payments;

  @override
  int get contactCount => contacts;

  @override
  int get addressLabelCount => labels;

  @override
  RestoreReport? get lastRestoreReport => null;

  @override
  int get unrecordedOutgoingCount => 0;

  @override
  LocationStatus statusOf(String locationId) => LocationStatus(
    id: locationId,
    enabled: on.contains(locationId),
    available: true,
    lastUpload: _lastSync,
  );

  @override
  Future<bool> isEnabled() async => true;

  @override
  Future<bool> isLocationEnabled(String id) async => on.contains(id);

  @override
  Future<void> setEnabled(
    bool enabled, {
    Iterable<String> locations = const [],
    bool reportRestore = false,
  }) async {}

  @override
  Future<void> setLocationEnabled(String id, bool enabled) async {}

  @override
  Future<int> filesIn(String id) async => 0;

  @override
  Future<void> sync({bool reportRestore = false}) async {}

  @override
  Future<void> carryImportIntoWallets() async {}

  @override
  Future<void> open(
    SeedSource seed, {
    required List<CryptoWallet> wallets,
    bool restored = false,
  }) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> deleteLocal() async {}

  @override
  void contactsChanged() {}

  @override
  void addressLabelsChanged() {}

  @override
  void historyChanged(CryptoWallet wallet) {}

  @override
  void outgoingPaymentSent(
    CryptoWallet wallet, {
    required String txid,
    required int accountIndex,
    required BigInt fee,
    required List<TxRecipient> recipients,
    required String txKey,
  }) {}

  @override
  BackedUpPayment? outgoingPayment(CryptoWallet wallet, String txid) => null;
}
