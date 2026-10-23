// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'fhse_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class FhseLocalizationsPt extends FhseLocalizations {
  FhseLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get advancedSecurityLabel => 'Advanced Security';

  @override
  String get advancedSecurityTitle => 'Advanced Security';

  @override
  String get advancedSecurityOff => 'Desativada';

  @override
  String advancedSecurityKeyCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chaves',
      one: '1 chave',
    );
    return '$_temp0';
  }

  @override
  String get advancedSecurityNeedsAttention => 'Precisa de atenção';

  @override
  String get securityKeysUnreadableTitle => 'Configure suas chaves de segurança novamente';

  @override
  String get securityKeysUnreadableBody =>
      'Isso acontece depois de trocar de celular. Sua carteira está segura e sua frase de recuperação ainda a abre. Configure suas chaves novamente ou desative as chaves de segurança.';

  @override
  String get securityKeysLoadFailed =>
      'Não foi possível carregar as configurações da sua chave de segurança.';

  @override
  String get securityKeysIntroTitle => 'Proteja esta carteira com uma chave de segurança';

  @override
  String get securityKeysIntroBody =>
      'A Advanced Security é uma camada extra de proteção para sua carteira, além do bloqueio do app. Quando ativada, sua carteira só pode ser aberta com sua chave de segurança e o PIN dela.';

  @override
  String get securityKeysRequirements =>
      'Funciona com a maioria das chaves de segurança físicas compatíveis com FIDO2 via NFC. Via USB, por enquanto só funcionam YubiKeys (no iPhone, com firmware 5.8 ou mais recente).';

  @override
  String get securityKeysSetUpButton => 'Configurar chaves de segurança';

  @override
  String securityKeysUnavailable(String appName) {
    return 'As chaves de segurança só funcionam com uma carteira criada ou restaurada nesta versão da $appName.';
  }

  @override
  String get securityKeysYourKeys => 'Suas chaves';

  @override
  String securityKeysAdded(String date) {
    return 'Adicionada em $date';
  }

  @override
  String get securityKeysOneKeyWarning =>
      'Você tem só uma chave. Adicione uma segunda como reserva. Sem uma chave, você vai precisar da sua frase de recuperação.';

  @override
  String get securityKeysAddButton => 'Adicionar uma chave de segurança';

  @override
  String get securityKeysManageSection => 'Gerenciar';

  @override
  String get securityKeysRemoveTitle => 'Remover uma chave';

  @override
  String get securityKeysRemoveSubtitle => 'Configurar novamente sem essa chave';

  @override
  String get securityKeysRemoveLink => 'Configurar';

  @override
  String get securityKeysRemoveExplain =>
      'Para remover uma chave, configure novamente só com as chaves que você quer manter. Qualquer chave que ficar de fora para de funcionar. Tenha com você todas as chaves que vai manter.';

  @override
  String get securityKeysRemoveConfirm => 'Configurar novamente';

  @override
  String get securityKeysTurnOff => 'Desativar chaves de segurança';

  @override
  String get securityKeysTurnOffBody => 'Sua carteira voltará a abrir sem uma chave de segurança.';

  @override
  String get securityKeysTurnOffConfirm => 'Desativar';

  @override
  String get securityKeysTurnedOff => 'As chaves de segurança estão desativadas';

  @override
  String get securityKeysTurnedOn => 'As chaves de segurança estão ativadas';

  @override
  String get securityKeysLockSection => 'Bloqueio';

  @override
  String get securityKeysFullLockLabel => 'Bloquear arquivo da carteira após';

  @override
  String securityKeysFullLockDescription(String appName) {
    return 'Depois de todo esse tempo em segundo plano, a $appName bloqueia o arquivo da carteira. Você vai precisar de uma chave de segurança para abri-lo novamente.';
  }

  @override
  String securityKeysMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutos',
      one: '1 minuto',
    );
    return '$_temp0';
  }

  @override
  String securityKeysHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count horas',
      one: '1 hora',
    );
    return '$_temp0';
  }

  @override
  String get securityKeysBackgroundNote =>
      'Enquanto bloqueada, a carteira continua sincronizando e pode mostrar novos pagamentos, mas não pode gastar.';

  @override
  String get securityKeysSetupTitle => 'Configurar chaves de segurança';

  @override
  String get securityKeysSetupAgainTitle => 'Configurar chaves novamente';

  @override
  String get securityKeysSetupAgainNote =>
      'Adicione só as chaves que você quer manter. Qualquer chave que ficar de fora para de funcionar.';

  @override
  String get securityKeysSetupNote =>
      'Adicione cada chave de segurança que você quer usar e toque em Concluir.';

  @override
  String get securityKeysAddFirst => 'Adicione sua primeira chave';

  @override
  String get securityKeysAddAnother => 'Adicionar outra chave';

  @override
  String get securityKeysFinish => 'Concluir';

  @override
  String get securityKeysOneKeyTitle => 'Usar só uma chave?';

  @override
  String get securityKeysOneKeyBody =>
      'Recomendamos pelo menos duas. Se você perder sua única chave, vai precisar da sua frase de recuperação.';

  @override
  String get securityKeysFinishAnyway => 'Usar uma chave';

  @override
  String get securityKeysNameLabel => 'Nome da chave';

  @override
  String securityKeysNameDefault(int number) {
    return 'Chave de segurança $number';
  }

  @override
  String get securityKeysPinLabel => 'PIN da chave';

  @override
  String get securityKeysContinue => 'Continuar';

  @override
  String get securityKeysNewPinTitle => 'Crie um PIN para esta chave';

  @override
  String get securityKeysNewPinLabel => 'Novo PIN';

  @override
  String get securityKeysConfirmPinLabel => 'Confirme o PIN';

  @override
  String get securityKeysSetPinButton => 'Definir PIN';

  @override
  String get securityKeysPinMismatch => 'Os PINs não coincidem.';

  @override
  String securityKeysErrorPinInvalid(int count) {
    return 'PIN incorreto. Restam $count tentativas antes de a chave bloquear.';
  }

  @override
  String get securityKeysErrorPinInvalidUnknown => 'PIN incorreto.';

  @override
  String get securityKeysErrorPinBlocked =>
      'Esta chave está bloqueada depois de muitos PINs errados. Ela só pode ser redefinida, e uma chave redefinida não abre mais nenhuma carteira.';

  @override
  String get securityKeysErrorPinAuthBlocked =>
      'Muitos PINs errados. Desconecte a chave e conecte-a novamente.';

  @override
  String get securityKeysErrorPinPolicy =>
      'A chave não aceitou esse PIN. Algumas chaves exigem 6 ou mais caracteres.';

  @override
  String get securityKeysErrorNotEnrolled => 'Esta chave não está configurada para esta carteira.';

  @override
  String get securityKeysErrorNotThisWallet =>
      'As configurações da sua chave de segurança não correspondem a esta carteira. Abra-a com sua frase de recuperação e configure suas chaves novamente.';

  @override
  String get securityKeysErrorAlreadyAdded => 'Esta chave já está configurada para esta carteira.';

  @override
  String securityKeysErrorUnsupported(String reason) {
    return 'Esta chave não pode ser usada aqui: $reason';
  }

  @override
  String get securityKeysErrorTimeout => 'Nenhuma chave foi encontrada. Tente novamente.';

  @override
  String get securityKeysErrorTransport => 'A conexão com sua chave caiu. Tente novamente.';

  @override
  String securityKeysErrorGeneric(String reason) {
    return 'Algo deu errado: $reason';
  }

  @override
  String get securityKeyUnlockTitle => 'Desbloqueie com sua chave de segurança';

  @override
  String get securityKeyUnlockButton => 'Desbloquear';

  @override
  String get securityKeyLostKeys => 'Perdeu suas chaves?';

  @override
  String get securityKeyLostKeysBody =>
      'Abra a carteira com sua frase de recuperação e configure novas chaves nas Configurações.';

  @override
  String get securityKeyUseRecoveryPhrase => 'Usar frase de recuperação';

  @override
  String get securityKeyRecoveryPhraseHint => 'Insira sua frase de recuperação';

  @override
  String get securityKeyRecoveryWrongPhrase =>
      'Essa frase de recuperação não corresponde a esta carteira.';

  @override
  String get securityKeyRecoveryNotPossible =>
      'Esta carteira foi restaurada de uma frase de recuperação de 25 palavras, que não pode desbloqueá-la aqui. Exclua a carteira e restaure-a a partir dessa frase.';

  @override
  String get securityKeyRecoveredToast =>
      'Desbloqueada com sua frase de recuperação. Configure suas chaves novamente nas Configurações.';

  @override
  String get securityKeyConnectTitle => 'Conecte sua chave de segurança';

  @override
  String get securityKeyConnectBodyAndroid =>
      'Conecte sua chave de segurança e toque nela quando piscar, ou encoste-a na parte de trás do celular.';

  @override
  String get securityKeyConnectBodyIos =>
      'Aproxime sua chave de segurança da parte de cima do iPhone, ou conecte-a e toque nela quando piscar.';

  @override
  String get securityKeyConnectButton => 'Conectar chave';

  @override
  String get securityKeyTryAgain => 'Tentar novamente';

  @override
  String get securityKeyWaiting => 'Aguardando sua chave…';

  @override
  String get securityKeyTalkingToKey => 'Conectando à sua chave…';

  @override
  String get securityKeyKeyBlinking => 'Sua chave está piscando';

  @override
  String get securityKeyTouchToSelect => 'Toque na sua chave';

  @override
  String get securityKeyTouchBody => 'Toque na sua chave de segurança enquanto ela pisca.';

  @override
  String get securityKeyPinTitle => 'Insira o PIN da sua chave';

  @override
  String get securityKeyPinBody =>
      'Este é o PIN da sua chave de segurança, não o código do seu celular.';

  @override
  String securityKeyPinAttemptsLeft(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Restam $count tentativas antes de a chave bloquear.',
      one: 'Resta 1 tentativa antes de a chave bloquear.',
    );
    return '$_temp0';
  }

  @override
  String get securityKeyUseAnotherKey => 'Usar outra chave';

  @override
  String get securityKeyUseFingerprint => 'Usar impressão digital';

  @override
  String get securityKeyUsePin => 'Usar PIN';

  @override
  String securityKeysNewPinBodyCount(int count) {
    return 'Esta chave ainda não tem PIN. Escolha um com pelo menos $count caracteres, para que quem encontrar sua chave não consiga usá-la.';
  }

  @override
  String securityKeysPinTooShortCount(int count) {
    return 'Use pelo menos $count caracteres.';
  }

  @override
  String get securityKeyCheckingPin => 'Verificando seu PIN…';

  @override
  String get securityKeyWorking => 'Um momento…';

  @override
  String get securityKeyKeepHolding => 'Continue segurando sua chave junto ao celular.';

  @override
  String get securityKeyHoldAgain => 'Encoste sua chave no celular novamente';

  @override
  String get securityKeyConnectAgain => 'Conecte sua chave novamente';

  @override
  String get securityKeyTouchToConfirm => 'Toque na sua chave para confirmar';

  @override
  String get securityKeyTouchOnceMore => 'Toque na sua chave mais uma vez';

  @override
  String get securityKeyTouchToUnlock => 'Toque na sua chave para desbloquear';

  @override
  String get securityKeyFingerprintToConfirm => 'Toque no sensor de impressão digital';

  @override
  String get securityKeyFingerprintOnceMore => 'Toque no sensor mais uma vez';

  @override
  String get securityKeyFingerprintToUnlock => 'Toque no sensor para desbloquear';

  @override
  String get securityKeyFingerprintBody =>
      'Use um dedo que você cadastrou nesta chave de segurança.';

  @override
  String securityKeyTouchCount(int current, int total) {
    return 'Toque $current de $total';
  }

  @override
  String get securityKeyAddedTitle => 'Chave adicionada';

  @override
  String get securityKeyNameBody => 'Dê um nome a ela para diferenciar suas chaves.';

  @override
  String get securityKeySaveName => 'Salvar';

  @override
  String get securityKeysErrorKeyUnsupported =>
      'Esta chave de segurança não é compatível. Tente outra.';

  @override
  String get securityKeysErrorPinChangeRequired =>
      'Esta chave de segurança precisa de um novo PIN primeiro. Altere-o com o app do fabricante da chave e tente novamente.';

  @override
  String securityKeysErrorUvInvalid(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Impressão digital não reconhecida. Restam $count tentativas.',
      one: 'Impressão digital não reconhecida. Resta 1 tentativa.',
    );
    return '$_temp0';
  }

  @override
  String get securityKeysErrorUvInvalidUnknown => 'Impressão digital não reconhecida.';

  @override
  String get securityKeysErrorUvBlocked =>
      'A impressão digital está bloqueada nesta chave. Insira o PIN dela.';

  @override
  String get securityKeysErrorUvNotConfigured =>
      'Esta chave não tem impressão digital configurada. Insira o PIN dela.';

  @override
  String securityKeyPinTitleNamed(String name) {
    return 'Insira o PIN de $name';
  }

  @override
  String securityKeysSerial(String serial) {
    return 'Nº de série $serial';
  }

  @override
  String get securityKeysErrorDifferentKey =>
      'Esta não é a chave que você tocou. Comece de novo com a chave que você quer usar.';

  @override
  String get securityKeysErrorMultipleKeys =>
      'Há mais de uma chave de segurança conectada. Desconecte as outras e tente novamente.';

  @override
  String get unlockBoundToAnotherPc =>
      'Esta carteira não pode ser aberta neste PC. Se você a criou neste PC, reinicie o PC e tente novamente. Caso contrário, restaure a carteira a partir da frase de recuperação dela.';

  @override
  String get securityKeysCancel => 'Cancelar';

  @override
  String get securityKeysPinEmpty => 'Insira seu PIN.';

  @override
  String get securityKeysSharedPhraseWarning =>
      'Sua carteira é tão forte quanto a proteção mais fraca. Guarde sua frase de recuperação em segurança e, se você usa a mesma carteira em vários dispositivos, configure a Advanced Security neles também.';

  @override
  String get securityKeysRequirementsMac =>
      'Funciona com a maioria das chaves de segurança físicas compatíveis com FIDO2.';

  @override
  String get securityKeyConnectBodyMac =>
      'Conecte sua chave de segurança a este Mac e toque nela quando piscar.';

  @override
  String get securityKeyPinBodyMac =>
      'Este é o PIN da sua chave de segurança, não a senha do seu Mac.';

  @override
  String get desktopAutoLockLabel => 'Bloquear arquivo da carteira após';

  @override
  String desktopAutoLockDescription(String appName) {
    return 'Depois de todo esse tempo sem uso, a $appName bloqueia o arquivo da carteira.';
  }

  @override
  String get securityKeysRequirementsLinux =>
      'Funciona com a maioria das chaves de segurança físicas compatíveis com FIDO2. Requer a libfido2, que a maioria dos sistemas Linux já tem.';

  @override
  String get securityKeysRequirementsWindows =>
      'Funciona com a maioria das chaves de segurança físicas compatíveis com FIDO2. Requer Windows 11 (22H2 ou mais recente).';

  @override
  String get securityKeysTurnOffBodyDesktop => 'Só a sua senha voltará a abrir a carteira.';

  @override
  String get securityKeyConnectBodyDesktop =>
      'Conecte sua chave de segurança a este computador e toque nela quando piscar.';

  @override
  String get securityKeyConnectBodyWindows =>
      'O Windows pede sua chave de segurança, o PIN dela e um toque.';

  @override
  String get securityKeyPinBodyDesktop =>
      'Este é o PIN da sua chave de segurança, não a senha da sua carteira.';

  @override
  String get securityKeyWindowsPromptTitle => 'Continue na Segurança do Windows';

  @override
  String get securityKeyWindowsPromptBody =>
      'Insira o PIN da sua chave de segurança e toque na chave.';

  @override
  String get securityKeyWindowsPromptEnrollBody =>
      'O Windows vai pedir duas vezes. Em cada uma, insira o PIN da sua chave de segurança e toque na chave.';

  @override
  String get securityKeyWindowsStorageNote =>
      'O Windows pode dizer que isto vai salvar algo na sua chave, mas essa mensagem genérica não é precisa. Isto não ocupa nenhum espaço de armazenamento na sua chave de segurança.';

  @override
  String get securityKeyWindowsWaiting => 'Aguardando a Segurança do Windows…';

  @override
  String get securityKeyUseButton => 'Usar chave de segurança';

  @override
  String get advancedSecurityAuthReason => 'Confirme sua identidade para abrir a Advanced Security';

  @override
  String get advancedSecurityAuthFailed => 'Não foi possível confirmar sua identidade.';

  @override
  String get advancedSecurityPasswordTitle => 'Digite sua senha';

  @override
  String advancedSecurityPasswordBody(String appName) {
    return 'Digite a senha que você usa para desbloquear a $appName.';
  }

  @override
  String get advancedSecurityPasswordLabel => 'Senha';

  @override
  String get advancedSecurityPasswordWrong => 'Senha incorreta.';

  @override
  String get advancedSecurityContinue => 'Continuar';

  @override
  String get appLockLabel => 'Bloquear app após';

  @override
  String get appLockImmediately => 'Imediatamente';

  @override
  String appLockDescriptionPhone(String appName) {
    return 'Quanto tempo a $appName pode ficar em segundo plano antes de pedir seu rosto, impressão digital ou código novamente.';
  }

  @override
  String appLockDescriptionMac(String appName) {
    return 'Quanto tempo a $appName pode ficar sem uso antes de pedir o Touch ID ou a senha do seu Mac novamente. Imediatamente a bloqueia assim que a janela é ocultada. A carteira continua sincronizando.';
  }

  @override
  String appLockDescriptionPassword(String appName) {
    return 'Quanto tempo a $appName pode ficar sem uso antes de pedir sua senha novamente. Imediatamente a bloqueia assim que a janela é ocultada. A carteira continua sincronizando.';
  }

  @override
  String appLockNoDeviceLock(String appName) {
    return 'Este dispositivo não tem bloqueio de tela, então qualquer pessoa com ele em mãos pode abrir a $appName. Defina um código ou bloqueio de tela nos ajustes do dispositivo.';
  }

  @override
  String lockLaterAuthReason(String appName) {
    return 'Confirme sua identidade para bloquear a $appName com menos frequência';
  }

  @override
  String lockLaterPasswordBody(String appName) {
    return 'Um tempo maior deixa a $appName aberta por mais tempo. Digite a senha que você usa para desbloqueá-la.';
  }

  @override
  String get appLockUseRecoveryPhraseBody =>
      'Você pode acessar sua carteira com sua frase de recuperação. Isso só é recomendado como mecanismo de recuperação. Não deve ser a forma normal de acessar sua carteira.';
}
