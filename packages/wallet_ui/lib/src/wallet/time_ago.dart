import '../l10n/wallet_ui_localizations.dart';

/// [then] in words, relative to [now] ("3 days ago", "about a month ago").
///
/// The wording and thresholds are the `timeago` package's, which the apps
/// used for their activity rows before the shared timeline replaced them with
/// day headers; the strings now live in [WalletUiLocalizations], so no
/// package is needed for them. A time in the future reads as just now.
String timeAgo(WalletUiLocalizations strings, DateTime then, {DateTime? now}) {
  final elapsed = (now ?? DateTime.now()).difference(then).inMilliseconds;
  final seconds = (elapsed < 0 ? 0 : elapsed) / 1000;
  final minutes = seconds / 60;
  final hours = minutes / 60;
  final days = hours / 24;
  if (seconds < 45) return strings.timeAgoMoment;
  if (seconds < 90) return strings.timeAgoMinute;
  if (minutes < 45) return strings.timeAgoMinutes(minutes.round());
  if (minutes < 90) return strings.timeAgoHour;
  if (hours < 24) return strings.timeAgoHours(hours.round());
  if (hours < 48) return strings.timeAgoDay;
  if (days < 30) return strings.timeAgoDays(days.round());
  if (days < 60) return strings.timeAgoMonth;
  if (days < 365) return strings.timeAgoMonths((days / 30).round());
  if (days / 365 < 2) return strings.timeAgoYear;
  return strings.timeAgoYears((days / 365).round());
}
