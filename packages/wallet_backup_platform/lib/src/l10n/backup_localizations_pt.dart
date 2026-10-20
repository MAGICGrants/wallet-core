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
  String get backupSeedWarningBold =>
      'Isto NÃO faz backup da sua frase de recuperação, que você ainda precisa guardar separadamente ou poderá perder seus fundos.';

  @override
  String get backupSeedWarning =>
      'Isto faz backup de dados adicionais que não ficam na blockchain, como certos dados de transações e sua agenda de endereços.';

  @override
  String get backupSecurityNote =>
      'Os arquivos de backup são protegidos com criptografia resistente a computadores quânticos. Eles derivam da sua frase de recuperação, então você pode restaurar qualquer backup com ela. Se você guardar seus backups num serviço de nuvem, ele não pode ver o conteúdo, mas pode ver certos metadados que você talvez considere sensíveis.';

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
  String get backupICloud => 'iCloud';

  @override
  String get backupICloudDescription =>
      'Os backups no iCloud são feitos pelo seu sistema operacional e não são protegidos pelo Tor.';

  @override
  String get backupAndroid => 'Backup do Android';

  @override
  String get backupAndroidDescription =>
      'Os backups do Android são feitos pelo seu sistema operacional e não são protegidos pelo Tor.';

  @override
  String get backupAndroidShort => 'Android';

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
  String get backupAndroidLarge => 'A cópia do Android está chegando ao limite de 25 MB.';

  @override
  String get backupFileSection => 'Arquivo de backup';

  @override
  String get backupExport => 'Salvar um arquivo de backup';

  @override
  String get backupExported => 'Arquivo de backup salvo';

  @override
  String get backupImport => 'Importar um arquivo de backup';

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
  String get backupDeleteAndroid => 'Apagar a cópia do backup do Android';

  @override
  String get backupDeleteAndroidBody =>
      'Remove o backup desta carteira que o Android restaurou neste aparelho, para que o próximo backup do Android não o leve mais.';

  @override
  String get backupDeletedAndroid => 'Cópia do backup do Android apagada';

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
  String get backupEnable => 'Fazer backup dos detalhes dos pagamentos';

  @override
  String get backupAutomaticSection => 'Automático (Recomendado)';

  @override
  String get backupManualSection => 'Manual';

  @override
  String get backupFileDescription => 'Salve manualmente uma cópia instantânea onde quiser.';

  @override
  String get backupDeleteLocal => 'Apagar a cópia neste aparelho';

  @override
  String get backupDeleteLocalTitle => 'Apagar a cópia neste aparelho?';

  @override
  String get backupDeleteLocalBody =>
      'Desativa o iCloud e o backup do Android e apaga o backup neste aparelho. Cópias já no iCloud ou em arquivos de backup salvos ficam até você apagá-las.';

  @override
  String get backupDeletedLocal => 'Backup neste aparelho apagado';

  @override
  String get importTitle => 'Importar dados da carteira';

  @override
  String get importIntro =>
      'Se você tem um arquivo de backup, pode restaurá-lo aqui. Você pode mudar isso depois nas configurações.';

  @override
  String importFromLocation(String where) {
    return 'Do $where';
  }

  @override
  String importFromLocationNote(String where) {
    return 'Se encontrado, isto também ativa os backups automáticos no $where.';
  }

  @override
  String get importFromFile => 'De um arquivo de backup';

  @override
  String get importFromFileNote =>
      'Isto não ativa os backups automáticos, que sugerimos ativar nas configurações.';

  @override
  String get importNo => 'Pular';

  @override
  String get importNoNote => 'Você pode restaurar de backups automáticos ou manuais depois.';

  @override
  String importLooking(String where) {
    return 'Procurando no $where…';
  }

  @override
  String get importReading => 'Lendo o arquivo de backup…';

  @override
  String get importNotFoundTitle => 'Nenhum backup encontrado';

  @override
  String get importOk => 'OK';

  @override
  String importNotFound(String where) {
    return 'Nenhum backup desta carteira no $where.';
  }

  @override
  String importUnavailable(String where) {
    return 'Não foi possível acessar o $where. Verifique se está ativado neste aparelho e tente de novo.';
  }

  @override
  String get importDoneTitle => 'Dados da carteira importados';

  @override
  String get importScanNote =>
      'Os detalhes de cada pagamento aparecem quando a carteira terminar de sincronizar.';

  @override
  String importLocationOn(String where) {
    return 'O backup no $where está ativado. Você pode desativá-lo em Configurações > Backup.';
  }

  @override
  String get importFileBackupNote =>
      'Os backups automáticos estão desativados. Salve um arquivo de backup em Configurações > Backup para guardar uma cópia.';

  @override
  String get importDone => 'Concluído';
}
