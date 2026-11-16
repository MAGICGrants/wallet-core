import 'package:flutter/widgets.dart';

import 'wallet_ui_localizations.dart';

/// The shared strings, for a widget in this package that names itself to
/// screen readers (an icon-only button, a step counter). Null where no app
/// registered [WalletUiLocalizations.delegate], as in a bare widget test: the
/// widget then goes unnamed instead of throwing.
WalletUiLocalizations? uiStringsOf(BuildContext context) =>
    Localizations.of<WalletUiLocalizations>(context, WalletUiLocalizations);
