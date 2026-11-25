import 'package:wallet_domain/wallet_domain.dart' show TxBuildFailure, TxBuildProblem;

import '../l10n/wallet_ui_localizations.dart';

extension SendFailureMessages on WalletUiLocalizations {
  /// What a Send form says when `createTx` failed with [error], after the app
  /// has handled the failures it marks on a field (low funds, gas).
  ///
  /// Only a failure the wallet classified gets its own words. Anything else
  /// stays "Unknown error.", and the wallet's log has the backend's reason.
  String txBuildFailureMessage(Object error) => switch (error) {
    TxBuildFailure(problem: TxBuildProblem.notConnected) => sendNoConnectionError,
    TxBuildFailure(problem: TxBuildProblem.coinsNotVerified) => sendCoinsNotVerifiedError,
    _ => unknownError,
  };
}
