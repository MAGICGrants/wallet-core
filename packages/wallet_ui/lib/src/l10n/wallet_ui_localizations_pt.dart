// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'wallet_ui_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class WalletUiLocalizationsPt extends WalletUiLocalizations {
  WalletUiLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get restoreWalletTitle => 'Restaurar Carteira';

  @override
  String get verifySeedTitle => 'Verificar Frase de Recuperação';

  @override
  String get createNewWalletChoice => 'Criar Nova Carteira';

  @override
  String get restoreExistingWalletChoice => 'Restaurar Carteira Existente';

  @override
  String get clearnetOnlyChoice => 'Somente Clearnet';

  @override
  String get noTransactions => 'Sem transações';

  @override
  String get addressBookNoContacts => 'Nenhum contato ainda';

  @override
  String get addressBookNoSearchResults => 'Nenhum contato encontrado';

  @override
  String generateSeedConfirm(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'todas as $count palavras',
      zero: 'todas as palavras',
    );
    return 'Anotei $_temp0 e as guardei em um lugar que só eu posso acessar.';
  }

  @override
  String get unlockWalletReason => 'Desbloquear carteira';

  @override
  String get torUseOrbotLabel => 'Usar Orbot/InviZible';

  @override
  String get torUseOrbotLabelIos => 'Usar Orbot';

  @override
  String get continueText => 'Continuar';

  @override
  String get cancel => 'Cancelar';

  @override
  String get close => 'Fechar';

  @override
  String get back => 'Voltar';

  @override
  String get unknownError => 'Erro desconhecido.';

  @override
  String get warning => 'Atenção';

  @override
  String get amount => 'Valor';

  @override
  String get networkFee => 'Taxa da Rede';

  @override
  String get address => 'Endereço';

  @override
  String get pending => 'Pendente';

  @override
  String get unconfirmed => 'Não confirmado';

  @override
  String get copy => 'Copiar';

  @override
  String get addressCopied => 'Endereço copiado para a área de transferência';

  @override
  String get copiedToClipboard => 'Copiado para a área de transferência';

  @override
  String get fieldEmptyError => 'Este campo não pode ficar vazio.';

  @override
  String get settingsLicensesLabel => 'Licenças de Código Aberto';

  @override
  String get torChoiceTitle => 'Configuração da Conexão Tor';

  @override
  String torChoiceBuiltInDesc(String appName) {
    return 'Incluído na $appName Wallet · recomendado';
  }

  @override
  String get torChoiceExternalDesc => 'Orbot, ou um daemon que você mesmo executa';

  @override
  String get torChoiceNoTorDesc =>
      'Os servidores aos quais você se conecta podem ver seu endereço IP';

  @override
  String get torChoiceTestFailed => 'Falha no teste';

  @override
  String get torChoiceConnected => 'Conectado ao Tor';

  @override
  String get connectionTypeLws => 'Servidor Light Wallet';

  @override
  String get connectionTypeNode => 'Nó Monero';

  @override
  String get lwsSetupUseTorLabel => 'Usar Tor';

  @override
  String get lwsSetupTestConnectionButton => 'Testar Conexão';

  @override
  String get connectionTestingTitle => 'Testando conexão';

  @override
  String get connectionTestingDetail => 'Verificando se o servidor responde.';

  @override
  String get connectionTestStop => 'Parar';

  @override
  String get connectionResultWorksTitle => 'A conexão funciona';

  @override
  String get connectionReachedOverTor => 'Acessado via Tor';

  @override
  String get connectionReachedViaProxy => 'Acessado pelo seu proxy';

  @override
  String get connectionReachedDirect => 'Acessado diretamente';

  @override
  String get connectionResultFailedTitle => 'Não foi possível acessar este servidor';

  @override
  String get connectionResultFailedDetail =>
      'Nada respondeu. Verifique o endereço e a porta, e se o servidor aceita sua conexão.';

  @override
  String get connectionTestAgain => 'Testar Novamente';

  @override
  String get lwsSetupStartingTor => 'Iniciando Tor...';

  @override
  String get lwsSetupContinueButton => 'Continuar';

  @override
  String get fiatApiSetupTitle => 'Configuração de Exibição de Preços';

  @override
  String get fiatApiSettingsModeLabel => 'Modo';

  @override
  String get fiatApiSettingsModeTorOnly => 'Somente Tor';

  @override
  String get fiatApiSettingsModeDisabled => 'Desativado';

  @override
  String get fiatModeTorOnlyDesc => 'Preços buscados pelo Tor · recomendado';

  @override
  String get fiatModeClearnetDesc => 'Não privado, o servidor de preços vê seu endereço IP';

  @override
  String get fiatModeDisabledDesc => 'Sem preços; saldos exibidos apenas em cripto';

  @override
  String get settingsOpenAliasSettingsLabel => 'Configurações do OpenAlias';

  @override
  String get openAliasSettingsSheetSubtitle =>
      'Como nomes como nome@exemplo.com são consultados quando você envia.';

  @override
  String get openAliasModeTorOnlyDesc => 'Nomes consultados pelo Tor · recomendado';

  @override
  String get openAliasModeClearnetDesc =>
      'Não privado, os servidores DNS veem seu endereço IP e o nome';

  @override
  String get openAliasModeDisabledDesc => 'Sem consultas; envie apenas para endereços';

  @override
  String get fiatApiSettingsDisplayCurrencyLabel => 'Moeda de Exibição';

  @override
  String get settingsFiatApiSettingsLabel => 'Configurações de Exibição de Preços';

  @override
  String get fiatApiSettingsSheetSubtitle =>
      'Como os preços são obtidos e a moeda em que são exibidos.';

  @override
  String get createWalletTitle => 'Configuração da Carteira';

  @override
  String get createWalletPasswordTitle => 'Criar Senha da Carteira';

  @override
  String get createWalletPasswordDescription =>
      'Crie uma senha para proteger sua carteira. Esta senha será necessária para desbloquear sua carteira.';

  @override
  String get createWalletPasswordHint => 'Digite sua senha';

  @override
  String get createWalletConfirmPasswordHint => 'Confirme sua senha';

  @override
  String get passwordTooShortError => 'A senha deve ter pelo menos 8 caracteres.';

  @override
  String get passwordsDoNotMatchError => 'As senhas não coincidem.';

  @override
  String get generateSeedTitle => 'Anote Estas Palavras, em Ordem';

  @override
  String get generateSeedTitleCovered => 'Frase de Recuperação';

  @override
  String get generateSeedSubtitleRevealed => 'Guarde-as em segurança. Não as compartilhe.';

  @override
  String get generateSeedScreenshotNote =>
      'As capturas de tela estão bloqueadas nesta tela. Certifique-se de que ninguém está olhando por cima do seu ombro.';

  @override
  String get generateSeedReveal => 'Toque para Revelar';

  @override
  String get generateSeedBirthdayLabel => 'Aniversário da Carteira';

  @override
  String get generateSeedBirthdayReason => 'Onde uma futura restauração começa a escanear';

  @override
  String get onboardingPriceNoteRatesOnly =>
      'Apenas os preços são solicitados. Seus endereços e saldos não são enviados.';

  @override
  String get onboardingPriceNoteTor => 'Os preços são buscados pelo Tor por padrão.';

  @override
  String get onboardingTorNotePrivacy => 'Conexões pelo Tor podem ser mais lentas.';

  @override
  String get onboardingTorNoteChangeable => 'Você pode alterar isso depois nas Configurações.';

  @override
  String get onboardingPasswordNoteLaunch =>
      'Você precisa desta senha para abrir sua carteira e para ver sua frase de recuperação.';

  @override
  String get onboardingPasswordNoteNotCloud =>
      'Esta senha não pode ser recuperada. Se você a perder, restaure sua carteira a partir da sua frase de recuperação.';

  @override
  String get onboardingPasswordStrong => 'Forte';

  @override
  String get onboardingPasswordMatch => 'As senhas coincidem';

  @override
  String onboardingWalletNoteGenerated(String appName) {
    return 'A $appName Wallet gera sua frase de recuperação neste dispositivo.';
  }

  @override
  String get onboardingWalletNoteRestore =>
      'Ao restaurar, uma data para escanear a partir dela torna a sincronização mais rápida.';

  @override
  String get lwsDetailsDescription =>
      'Se o seu servidor light wallet Monero (LWS) exigir registro, você pode usar estes dados para adicionar esta carteira a esse servidor. Nem todos os servidores exigem registro.';

  @override
  String get restoreWalletSeedLength => 'Número de Palavras';

  @override
  String get restoreWalletPaste => 'Colar';

  @override
  String get restoreWalletScanFrom => 'Escanear a Partir de';

  @override
  String get restoreWalletScanFromReason => 'Ignore o histórico irrelevante para economizar tempo';

  @override
  String get restoreWalletNotSet => 'Não definido';

  @override
  String get restoreScanTitle => 'Quando Esta Carteira Recebeu Fundos pela Primeira Vez?';

  @override
  String get restoreScanPickMonth => 'Escolher um Mês';

  @override
  String get restoreScanNotSure => 'Não Tenho Certeza';

  @override
  String get restoreScanNotSureDesc =>
      'Escanear tudo. Mais lento nesta configuração inicial, mas não depois. Sempre completo.';

  @override
  String get restoreScanFromStart => 'Genesis';

  @override
  String get restoreScanDone => 'Concluir';

  @override
  String restoreWalletBadWord(int position) {
    return 'A palavra $position não é uma palavra BIP39.';
  }

  @override
  String restoreWalletDidYouMean(String word) {
    return 'Você quis dizer $word?';
  }

  @override
  String get restoreWalletChecksumError =>
      'Esta não é uma frase de recuperação válida — verifique as palavras e a ordem.';

  @override
  String get restoreWalletRestoreButton => 'Restaurar';

  @override
  String get navigationBarSettings => 'Configurações';

  @override
  String get navigationBarHistory => 'Histórico';

  @override
  String get historyTitle => 'Histórico';

  @override
  String get historyExportCsv => 'Exportar CSV';

  @override
  String get historyExported => 'Histórico exportado';

  @override
  String get historyExportFailed => 'Não foi possível exportar o histórico';

  @override
  String get historyFilterType => 'Tipo';

  @override
  String get historyFilterReset => 'Redefinir';

  @override
  String get unlockButton => 'Desbloquear';

  @override
  String get unlockUnableToAuthError => 'Não foi possível autenticar.';

  @override
  String get unlockWithFaceId => 'Desbloquear com Face ID';

  @override
  String get unlockWithTouchId => 'Desbloquear com Touch ID';

  @override
  String get unlockPasswordHint => 'Digite sua senha';

  @override
  String get unlockIncorrectPasswordError => 'Senha incorreta. Tente novamente.';

  @override
  String get homeSyncing => 'Sincronizando';

  @override
  String get homeSynced => 'Sincronizado';

  @override
  String get homeTorConnected => 'Tor · conectado';

  @override
  String get homeTorConnecting => 'Tor · conectando';

  @override
  String get homeTorDisconnected => 'Tor · desconectado';

  @override
  String get homeTorOff => 'Tor · desligado';

  @override
  String get homeTorExternalConnected => 'Tor externo · conectado';

  @override
  String get homeTorExternalConnecting => 'Tor externo · conectando';

  @override
  String get homeTorExternalDisconnected => 'Tor externo · desconectado';

  @override
  String homeBlocksRemaining(int count) {
    final intl.NumberFormat countNumberFormat = intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString blocos restantes',
      one: '1 bloco restante',
    );
    return '$_temp0';
  }

  @override
  String get coinHomeActivityTitle => 'Atividade';

  @override
  String get coinHomeSwap => 'Trocar';

  @override
  String get coinHomeSwapComingSoon => 'Em breve!';

  @override
  String get coinHomeReceived => 'Recebido';

  @override
  String get coinHomeSent => 'Enviado';

  @override
  String get homeReceive => 'Receber';

  @override
  String get homeSend => 'Enviar';

  @override
  String get homeFiatApiError => 'Erro ao conectar ao servidor de preços';

  @override
  String get receiveTitle => 'Receber';

  @override
  String get receivePrimaryAddressWarn =>
      'A menos que saiba o que está fazendo, por favor use subendereços para melhor privacidade.';

  @override
  String get receiveServerNoSubaddressesWarn =>
      'Este servidor não suporta subendereços. Para melhor privacidade, considere usar um servidor que os suporte.';

  @override
  String get receiveSubaddressUnavailableWarn =>
      'Você precisa configurar o Monero para ativar subendereços, que protegem melhor sua privacidade.';

  @override
  String get receiveMaxSubaddressesReachedWarn =>
      'Você atingiu o número máximo de subendereços suportados por este servidor. Este é um endereço já usado.';

  @override
  String get receiveSubaddressTab => 'Subendereço';

  @override
  String get receivePrimaryTab => 'Endereço Primário';

  @override
  String get receiveCopyAddress => 'Copiar Endereço';

  @override
  String get receiveEnlargeQr => 'Toque para Ampliar e Aumentar o Brilho';

  @override
  String get receiveShrinkQr => 'Toque para Reduzir';

  @override
  String get receiveShareError => 'Não foi possível abrir a janela de compartilhamento';

  @override
  String receiveAddressHeading(String coin) {
    return 'Seu Endereço $coin';
  }

  @override
  String get sendTitle => 'Enviar';

  @override
  String get sendSendButton => 'Enviar';

  @override
  String get sendTransactionSuccessfullySent => 'Transação enviada com sucesso!';

  @override
  String get sendOpenAliasResolveError => 'OpenAlias inválido.';

  @override
  String get sendOpenAliasDisabledError => 'O OpenAlias está desligado. Ligue-o nas Configurações.';

  @override
  String get sendContactsButton => 'Contatos';

  @override
  String get sendInsufficientBalanceError => 'Saldo insuficiente.';

  @override
  String get sendInsufficientBalanceToCoverFeeError =>
      'Saldo insuficiente para cobrir a taxa da rede.';

  @override
  String get settingsTitle => 'Configurações';

  @override
  String get settingsSectionGeneral => 'Geral';

  @override
  String get settingsSectionSecurityPrivacy => 'Segurança e Privacidade';

  @override
  String get settingsSectionData => 'Dados';

  @override
  String get settingsSectionBehaviour => 'Comportamento';

  @override
  String get settingsSectionAbout => 'Sobre';

  @override
  String get settingsSectionWallet => 'Carteira';

  @override
  String get settingsNotifyNewTxsLabel => 'Notificações de Transações';

  @override
  String get settingsNotifyNewTxsDescription =>
      'Mostrar uma notificação quando você receber uma transação. Aumente a frequência de sincronização para vê-las mais cedo.';

  @override
  String get settingsSyncFrequencyLabel => 'Frequência de Sincronização';

  @override
  String get syncFrequencyContinuous => 'Contínua';

  @override
  String get syncFrequencyPeriodic => 'Periódica';

  @override
  String get syncFrequencyOff => 'Desligada';

  @override
  String get syncFrequencyOffDesc => 'Só sincroniza enquanto o app está aberto.';

  @override
  String get settingsLoggingLabel => 'Logs de Diagnóstico';

  @override
  String get settingsLoggingDescription =>
      'Registrar operações da carteira em um arquivo de texto na pasta de dados do app para fins de depuração.';

  @override
  String get settingsLoggingDescriptionIos =>
      'Registrar operações da carteira e permitir exportar os logs para um arquivo de texto.';

  @override
  String get settingsExportLogsLabel => 'Exportar Logs';

  @override
  String get settingsExportLogsButton => 'Exportar';

  @override
  String get settingsExportLogsError => 'Nenhum log encontrado para exportar.';

  @override
  String get settingsExportLogsFailed => 'Não foi possível exportar o arquivo de log';

  @override
  String get settingsThemeLabel => 'Tema';

  @override
  String get settingsThemeSystem => 'Sistema';

  @override
  String get settingsThemeLight => 'Claro';

  @override
  String get settingsThemeDark => 'Escuro';

  @override
  String get settingsThemeDarkDesc => 'Fundo escuro, melhor à noite';

  @override
  String get settingsThemeSystemDesc => 'Segue o seu telefone';

  @override
  String get settingsThemeSheetSubtitle => 'Escolha um tema que combine com seu estilo.';

  @override
  String get settingsLanguageLabel => 'Idioma';

  @override
  String get settingsLanguageSheetSubtitle => 'Escolha seu idioma e formato regional.';

  @override
  String get revealSeedAuthReason => 'Confirme sua identidade para ver a frase de recuperação';

  @override
  String get done => 'Concluir';

  @override
  String get settingsLwsViewKeysButton => 'Ver';

  @override
  String get settingsDeleteWalletButton => 'Excluir Carteira';

  @override
  String get settingsDeleteWalletDialogText =>
      'Tem certeza que deseja excluir sua carteira? Você perderá acesso à seus fundos, a menos que tenha anotado sua frase de recuperação. Isso não remove sua lista de contatos nem as configurações do app.';

  @override
  String get settingsDeleteWalletDialogDeleteButton => 'Excluir';

  @override
  String get settingsDeleteAddressBookButton => 'Excluir Lista de Contatos';

  @override
  String get settingsDeleteAddressBookDialogText =>
      'Tem certeza que deseja excluir sua lista de contatos? Se o backup automático estiver ligado, ela também será excluída desses backups automáticos.';

  @override
  String get settingsDeleteAddressBookDialogDeleteButton => 'Excluir';

  @override
  String get settingsAddressBookDeleted => 'Lista de contatos excluída';

  @override
  String get txDetailsTitle => 'Detalhes da Transação';

  @override
  String get txDetailsCopyHint => 'toque em qualquer valor para copiar';

  @override
  String get txDetailsHashLabel => 'Hash';

  @override
  String get txDetailsTimeAndDateLabel => 'Data e Hora';

  @override
  String get txDetailsConfirmationHeightLabel => 'Bloco de Confirmação';

  @override
  String get txDetailsConfirmationsLabel => 'Confirmações';

  @override
  String get txDetailsViewKeyLabel => 'Chave de Visualização';

  @override
  String get txDetailsRecipientsLabel => 'Destinatários';

  @override
  String get txDetailsReceivedAtLabel => 'Recebido em';

  @override
  String get txDetailsChangeRecipientLabel => 'Destinatário de Troco';

  @override
  String get txDetailsFailed => 'Esta transação falhou. Os fundos não foram enviados.';

  @override
  String get txDetailsUnknownStatus =>
      'Esta transação não foi confirmada como enviada. Verifique antes de enviar novamente.';

  @override
  String get lwsKeysTitle => 'Chaves do LWS';

  @override
  String get lwsKeysPrimaryAddress => 'Endereço Primário';

  @override
  String get lwsKeysRestoreHeight => 'Bloco de Restauração';

  @override
  String get lwsKeysSecretViewKey => 'Chave Privada de Visualização';

  @override
  String get lwsKeysWarning =>
      'As capturas de tela estão bloqueadas nesta tela. Certifique-se de que ninguém está olhando por cima do seu ombro.';

  @override
  String get scanQrTitle => 'Escanear QR Code';

  @override
  String get confirmSendTitle => 'Confirmar Envio';

  @override
  String get confirmSendDescription =>
      'As transações são irreversíveis, então verifique se estes detalhes correspondem exatamente.';

  @override
  String confirmSendHighFeeWarning(String percent) {
    return 'A taxa de rede é $percent do valor que você está enviando.';
  }

  @override
  String get addressBookTitle => 'Lista de Contatos';

  @override
  String get addressBookAddContact => 'Adicionar Contato';

  @override
  String get addressBookEditContact => 'Editar Contato';

  @override
  String get addressBookDeleteContact => 'Excluir Contato';

  @override
  String addressBookDeleteContactConfirmation(String contactName) {
    return 'Tem certeza que deseja excluir \"$contactName\"?';
  }

  @override
  String get addressBookDelete => 'Excluir';

  @override
  String get addressBookSearchHint => 'Pesquisar contatos...';

  @override
  String get addressBookNoContactsDescription => 'Adicione seu primeiro contato tocando no botão +';

  @override
  String get addressBookEdit => 'Editar';

  @override
  String get addressBookContactName => 'Nome do Contato';

  @override
  String get addressBookNameHint => 'Nome';

  @override
  String get addressBookUpdate => 'Atualizar';

  @override
  String get scanQrUnexpectedCode => 'Esse QR não é um endereço ou código de pagamento válido.';

  @override
  String deepLinkCoinNotConfigured(String chain) {
    return 'Por favor, configure sua conexão $chain primeiro.';
  }

  @override
  String get sendPriorityLow => 'Baixa';

  @override
  String get sendPriorityNormal => 'Normal';

  @override
  String get sendPriorityHigh => 'Alta';

  @override
  String get sendToLabel => 'Para';

  @override
  String get sendPriorityHeading => 'Prioridade';

  @override
  String get sendAvailableSuffix => 'disponível';

  @override
  String get sendSwitchUnit => 'Alternar Unidade do Valor';

  @override
  String get sendNetworkFee => 'Taxa de Rede';

  @override
  String get sendMaxButton => 'MÁX';

  @override
  String get sendPasteButton => 'Colar';

  @override
  String get sendScanButton => 'Escanear';

  @override
  String get sendPickContactTitle => 'Enviar para um Contato';

  @override
  String get sendFailedToGetFeesError => 'Não foi possível carregar taxas.';

  @override
  String get sendNoConnectionError =>
      'Não foi possível conectar ao servidor. Verifique sua conexão e tente novamente.';

  @override
  String get torSettingsTitle => 'Configurações do Tor';

  @override
  String get torSettingsModeBuiltIn => 'Tor Integrado';

  @override
  String get torSettingsModeExternal => 'Tor Externo';

  @override
  String get torSettingsModeDisabled => 'Sem Tor';

  @override
  String get torSettingsSocksPortLabel => 'Porta SOCKS';

  @override
  String get torSettingsTestConnectionButton => 'Testar Conexão';

  @override
  String get torDisabledWalletsWarningTitle => 'Desativar o Tor?';

  @override
  String get torDisabledWalletsWarningBody =>
      'Algumas carteiras estão configuradas para conectar via Tor. Desativar o Tor irá desconectá-las, e elas permanecerão desconectadas até que você reconfigure a conexão delas.';

  @override
  String get torDisabledWalletsWarningConfirm => 'Desativar o Tor';

  @override
  String get connectionRemoteIpNotAllowed =>
      'Conexões com endereços IP remotos não são permitidas. Use um nome de domínio ou um endereço IP local.';

  @override
  String get connectionLocalOverTorNotAllowed =>
      'Um endereço local não pode ser acessado via Tor. Desative o Tor ou use o endereço onion do servidor.';

  @override
  String get connectionOnionNeedsTor =>
      'Um endereço onion só pode ser acessado via Tor. Ative o Tor para usá-lo.';

  @override
  String get connectionPathNotSupported =>
      'Este servidor é acessado pela raiz, então o endereço não pode incluir um caminho como /wallet. Remova o caminho.';

  @override
  String get lwsAwaitingApprovalAccount =>
      'Seu servidor de carteira leve ainda não aprovou esta carteira. Peça ao operador do servidor para aprová-la para ver seu saldo e suas transações.';

  @override
  String get lwsAwaitingApprovalRestoreHeight =>
      'Seu servidor de carteira leve ainda não aprovou a verificação a partir da sua altura de restauração, então transações mais antigas podem estar faltando. Peça ao operador do servidor para aprová-la.';

  @override
  String get connectionTorDisabledWarning =>
      'O Tor está desativado, então esta conexão não funciona mais. Reconfigure-a.';

  @override
  String get connectionProtocolHttps => 'Removendo protocolo. Usando HTTPS para domínios.';

  @override
  String get connectionProtocolHttp => 'Removendo protocolo. Usando HTTP para endereços locais.';

  @override
  String get connectionProtocolHttpOnion =>
      'Removendo protocolo. Endereços onion usam HTTP via Tor.';

  @override
  String get settingsTorSettingsLabel => 'Configurações do Tor';

  @override
  String get lwsSetupTorDisabledError => 'O Tor está desativado. Por favor, volte e ative-o.';

  @override
  String get homeIncomingTitle => 'A receber';

  @override
  String homeIncomingUnlocksIn(int minutes, int done, int needed) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minutos',
      one: '1 minuto',
    );
    return 'Desbloqueia em cerca de $_temp0 · $done de $needed';
  }

  @override
  String homeIncomingConfirmations(int done, int needed) {
    return '$done de $needed confirmações';
  }

  @override
  String get homeChartTitle => 'Saldo · 90 dias';

  @override
  String get homeChartToday => 'Hoje';

  @override
  String get homeChartEachCoin => 'Saldo de cada moeda';

  @override
  String get homeChartNew => 'Novo';

  @override
  String get homeChartEmpty =>
      'Seu saldo ao longo do tempo aparece aqui após sua primeira transação.';

  @override
  String get homeChecklistTitle => 'Proteja Sua Carteira';

  @override
  String homeChecklistProgress(int done, int total) {
    return '$done de $total';
  }

  @override
  String get homeChecklistVerifySeed => 'Verifique Sua Frase de Recuperação';

  @override
  String get homeChecklistAutoBackup => 'Ative os Backups Automáticos';

  @override
  String get homeChecklistTor => 'Conecte-se pelo Tor';

  @override
  String get homeChecklistPrivateLookups => 'Use o Tor nas Consultas de Preço e OpenAlias';

  @override
  String get homeChecklistSecurityKeys => 'Configure uma Chave de Segurança';

  @override
  String verifySeedSubtitle(int first, int second, int third) {
    return 'Insira as palavras $first, $second e $third da sua frase de recuperação abaixo.';
  }

  @override
  String get verifySeedButton => 'Verificar';

  @override
  String get verifySeedWrongTitle => 'Essas palavras não conferem';

  @override
  String verifySeedWrongBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Restam $count tentativas',
      one: 'Resta 1 tentativa',
    );
    return 'Confira a frase de recuperação que você anotou e insira as três novas palavras pedidas. $_temp0 antes de o app bloquear.';
  }

  @override
  String get verifySeedTryAgain => 'Tentar Novamente';

  @override
  String get verifySeedUnavailable =>
      'Não é possível ler sua frase de recuperação agora. Tente novamente depois de desbloquear a carteira.';

  @override
  String get verifySeedDone => 'Frase de recuperação verificada';

  @override
  String homeIncomingTitleMore(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Outras',
      one: '1 Outra',
    );
    return 'A receber (+$_temp0)';
  }

  @override
  String get save => 'Salvar';

  @override
  String get connectionSetupTitle => 'Configuração da Conexão';

  @override
  String generateSeedPasswordNote(String appName) {
    return 'A $appName Wallet pede sua senha antes de mostrar estas palavras novamente.';
  }
}
