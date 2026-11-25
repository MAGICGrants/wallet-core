import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// What a Send form says when the wallet couldn't build the transaction.
void main() {
  for (final locale in const [Locale('en'), Locale('pt')]) {
    final strings = lookupWalletUiLocalizations(locale);

    test('${locale.languageCode}: not connected says to check the connection', () {
      expect(
        strings.txBuildFailureMessage(
          const TxBuildFailure(TxBuildProblem.notConnected, detail: 'Tx construction: x'),
        ),
        strings.sendNoConnectionError,
      );
    });

    test('${locale.languageCode}: unverified coins say nothing was sent and name the server', () {
      expect(
        strings.txBuildFailureMessage(
          const TxBuildFailure(
            TxBuildProblem.coinsNotVerified,
            detail: 'the server misreported an input',
          ),
        ),
        strings.sendCoinsNotVerifiedError,
      );
    });

    test('${locale.languageCode}: anything else stays unknown, without the backend text', () {
      for (final error in [
        const TxBuildFailure(TxBuildProblem.other, detail: 'Invalid destination address'),
        Exception('insufficient funds for gas'),
        StateError('x'),
      ]) {
        expect(strings.txBuildFailureMessage(error), strings.unknownError);
      }
    });
  }
}
