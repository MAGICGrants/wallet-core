// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'backup_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class BackupLocalizationsPt extends BackupLocalizations {
  BackupLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get backupTitle => 'Backup';

  @override
  String get backupIntro =>
      'Para quem você pagou, a chave de transação de cada pagamento e seus contatos, criptografados com a sua frase de recuperação. Restaure a frase em qualquer lugar e eles voltam.';

  @override
  String get backupLegacySeed =>
      'O backup não está disponível para sementes de 25 palavras. Para usá-lo, crie uma carteira nova com uma semente de 16 palavras e envie seus fundos para ela.';

  @override
  String get backupUnsupportedPassphrase =>
      'O backup ainda não está disponível para sementes com senha de deslocamento.';

  @override
  String get backupLocked => 'Desbloqueie a carteira para ver o backup.';

  @override
  String get backupOpening => 'Abrindo o backup…';

  @override
  String backupSummary(int payments, int contacts) {
    String _temp0 = intl.Intl.pluralLogic(
      payments,
      locale: localeName,
      other: '$payments pagamentos',
      one: '1 pagamento',
    );
    String _temp1 = intl.Intl.pluralLogic(
      contacts,
      locale: localeName,
      other: '$contacts contatos',
      one: '1 contato',
    );
    return '$_temp0 e $_temp1 no backup';
  }

  @override
  String backupLastChecked(String time) {
    return 'Verificado $time';
  }

  @override
  String get backupWhereSaved => 'Onde fica salvo';

  @override
  String get backupICloud => 'iCloud';

  @override
  String get backupICloudDescription =>
      'Sincroniza com seus outros aparelhos Apple. Não aparece no app Arquivos.';

  @override
  String get backupAndroid => 'Backup do Android';

  @override
  String backupAndroidDescription(String appName) {
    return 'O Android copia cerca de uma vez por dia com sua conta Google ou o serviço de backup do aparelho, e o devolve quando você reinstala o $appName.';
  }

  @override
  String get backupLws => 'Servidor de carteira leve';

  @override
  String get backupComingSoon => 'Em breve';

  @override
  String get backupStatusUpToDate => 'Atualizado';

  @override
  String backupStatusPending(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count alterações aguardando envio',
      one: '1 alteração aguardando envio',
    );
    return '$_temp0';
  }

  @override
  String get backupStatusAwaiting => 'Entregue ao iCloud; aguardando o envio';

  @override
  String get backupStatusUnavailable => 'O iCloud Drive está desligado';

  @override
  String get backupStatusError => 'Não foi possível salvar; vamos tentar de novo';

  @override
  String get backupStatusOff => 'Desligado';

  @override
  String get backupAndroidLarge => 'A cópia do Android está chegando ao limite de 25 MB.';

  @override
  String get backupFileSection => 'Arquivo de backup';

  @override
  String get backupExport => 'Salvar um arquivo de backup';

  @override
  String get backupExportSubtitle =>
      'Um arquivo para guardar em outro lugar, como o Proton Drive ou um pendrive. Ele não se atualiza: salve um novo depois de enviar.';

  @override
  String get backupExported => 'Arquivo de backup salvo';

  @override
  String get backupImport => 'Importar um arquivo de backup';

  @override
  String get backupImportSubtitle => 'Adiciona a esta carteira o que o arquivo contém.';

  @override
  String backupImported(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count alterações novas importadas',
      one: '1 alteração nova importada',
    );
    return '$_temp0';
  }

  @override
  String get backupImportNothingNew => 'Nada de novo nesse arquivo';

  @override
  String get backupImportWrongWallet => 'Esse arquivo não é um backup desta carteira';

  @override
  String backupFailed(String error) {
    return 'Algo deu errado: $error';
  }

  @override
  String get backupTorNote =>
      'O iCloud e o backup do Android são feitos pelo sistema operacional e não passam pelo Tor.';

  @override
  String backupUnrecorded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count pagamentos enviados não têm registro no backup: foram enviados de outra carteira ou antes de o backup existir.',
      one:
          '1 pagamento enviado não tem registro no backup: foi enviado de outra carteira ou antes de o backup existir.',
    );
    return '$_temp0';
  }

  @override
  String get backupRestoreTitle => 'Última restauração';

  @override
  String backupRestoreSummary(int payments, int contacts) {
    String _temp0 = intl.Intl.pluralLogic(
      payments,
      locale: localeName,
      other: '$payments pagamentos encontrados',
      one: '1 pagamento encontrado',
    );
    String _temp1 = intl.Intl.pluralLogic(
      contacts,
      locale: localeName,
      other: '$contacts contatos restaurados',
      one: '1 contato restaurado',
    );
    return '$_temp0; $_temp1.';
  }

  @override
  String backupRestoreUnreadable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count arquivos não puderam ser lidos.',
      one: '1 arquivo não pôde ser lido.',
    );
    return '$_temp0';
  }

  @override
  String get backupRestoreGaps =>
      'Faltam alterações feitas em outro aparelho. Abra a carteira nesse aparelho para que ele as envie.';

  @override
  String backupRestoreConflicts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pagamentos têm dois registros diferentes; os dois foram mantidos.',
      one: '1 pagamento tem dois registros diferentes; os dois foram mantidos.',
    );
    return '$_temp0';
  }

  @override
  String get backupDeleteICloud => 'Apagar a cópia do iCloud';

  @override
  String get backupDeleteICloudBody =>
      'Remove do iCloud o backup desta carteira. A cópia neste aparelho continua, e o iCloud a recebe de novo se o backup no iCloud estiver ligado.';

  @override
  String get backupDeleteConfirm => 'Apagar';

  @override
  String get backupCancel => 'Cancelar';

  @override
  String get backupDeleted => 'Cópia do iCloud apagada';

  @override
  String backupRestoreFound(int payments, int contacts) {
    String _temp0 = intl.Intl.pluralLogic(
      payments,
      locale: localeName,
      other: '$payments pagamentos',
      one: '1 pagamento',
    );
    String _temp1 = intl.Intl.pluralLogic(
      contacts,
      locale: localeName,
      other: '$contacts contatos',
      one: '1 contato',
    );
    return '$_temp0 e $_temp1 restaurados do backup';
  }

  @override
  String get backupNoneFoundTitle => 'Nenhum backup encontrado';

  @override
  String get backupNoneFoundBody =>
      'Se você salvou um arquivo de backup, importe-o agora para recuperar para quem você pagou e seus contatos.';

  @override
  String get backupSkip => 'Pular';
}
