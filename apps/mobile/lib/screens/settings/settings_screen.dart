import 'package:flutter/material.dart';
import 'package:mobile/providers/notification/notification_provider.dart';
import 'package:mobile/providers/preferences/preferences_provider.dart';
import 'package:mobile/providers/safety/block_provider.dart';
import 'package:mobile/providers/theme/theme_provider.dart';
import 'package:mobile/providers/user/user_provider.dart';
import 'package:mobile/routes/app_routes.dart';
import 'package:mobile/theme/app_spacing.dart';
import 'package:mobile/theme/theme_extensions.dart';
import 'package:mobile/theme/vibester_dialog.dart';
import 'package:mobile/utils/external_links.dart';
import 'package:mobile/widgets/common/screen_header.dart';
import 'package:mobile/widgets/common/settings_row.dart';
import 'package:mobile/widgets/motion/vibester_pressable.dart';
import 'package:provider/provider.dart';

/// Configurações.
///
/// A versão anterior desenhava cada grupo como um cartão arredondado de altura
/// fixa (`height: Platform.isIOS ? 190 : 150`) com divisórias internas — o que
/// quebra assim que o texto de um item quebra em duas linhas — e apresentava
/// como iguais tanto os itens que funcionavam quanto os oito que tinham
/// `onTap: () {}`. Aqui os grupos são apenas rótulos em DM Mono sobre linhas
/// separadas por fio, a altura vem do conteúdo, e **o que ainda não existe não
/// aparece**: nada de item "em breve" prometendo um destino que não abre.
///
/// Fora desta versão: "Ghost vibe" (switch só local, sem backend) e "Vibester
/// Club" (assinatura por checkout externo, fora das regras de compra da App
/// Store). O `PaymentService` continua no código para quando voltar.
///
/// PREFERÊNCIAS: grupo entre Aparência e Ajuda e privacidade, com dois
/// interruptores ligados de fábrica — "Deslizar para trocar de aba" e "Barras
/// flutuantes". Quem respeita cada um está listado no `PreferencesProvider`.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Future<void> _confirmarLogout() async {
    final colors = context.colors;

    final confirmar = await showVibesterDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surfaceRaised,
        title: Text(
          'Sair da conta',
          style: context.typography.titleLarge.copyWith(
            color: colors.textPrimary,
          ),
        ),
        content: Text(
          'Você vai precisar entrar de novo pra usar o app.',
          style: context.typography.bodyMedium.copyWith(
            color: colors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancelar',
              style: context.typography.titleSmall.copyWith(
                color: colors.textMuted,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Sair',
              style: context.typography.titleSmall.copyWith(
                color: colors.error,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmar != true || !mounted) return;

    final notificationProvider = context.read<NotificationProvider>();
    final blockProvider = context.read<BlockProvider>();
    await context.read<UserProvider>().logout();
    notificationProvider.clear();
    blockProvider.clear();

    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(
      context,
      AppRoutes.initialScreen,
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final themeProvider = context.watch<ThemeProvider>();
    final preferences = context.watch<PreferencesProvider>();

    return Scaffold(
      backgroundColor: colors.noturno,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.huge),
          children: [
            const ScreenHeader(title: 'Ajustes', eyebrow: 'SUA CONTA'),

            const SettingsGroupLabel('CONTA'),
            SettingsRow(
              icon: Icons.person_outline_rounded,
              label: 'Informações pessoais',
              onTap: () => Navigator.pushNamed(
                context,
                AppRoutes.personalInformationSettings,
              ),
            ),
            SettingsRow(
              icon: Icons.block_rounded,
              label: 'Contas bloqueadas',
              onTap: () =>
                  Navigator.pushNamed(context, AppRoutes.blockedAccounts),
            ),

            const SettingsGroupLabel('APARÊNCIA'),
            SettingsRow(
              icon: themeProvider.isDarkMode
                  ? Icons.dark_mode_outlined
                  : Icons.light_mode_outlined,
              label: themeProvider.isDarkMode ? 'Modo escuro' : 'Modo claro',
              // PREFERÊNCIAS: o `Switch` que ficava aqui virou o
              // `_SettingsSwitch` no fim do arquivo, sem mudar nada no
              // desenho — os três interruptores da tela usam o mesmo, então
              // não há como um sair diferente do outro.
              trailing: _SettingsSwitch(
                value: themeProvider.isDarkMode,
                onChanged: (_) => themeProvider.toggleTheme(),
              ),
            ),

            // PREFERÊNCIAS: mesma anatomia da linha do tema, mas o texto é
            // fixo — o interruptor sozinho diz se está ligado ou não.
            const SettingsGroupLabel('PREFERÊNCIAS'),
            SettingsRow(
              icon: Icons.swipe_outlined,
              label: 'Deslizar para trocar de aba',
              trailing: _SettingsSwitch(
                value: preferences.swipeBetweenTabs,
                onChanged: preferences.setSwipeBetweenTabs,
              ),
            ),
            SettingsRow(
              icon: Icons.call_to_action_outlined,
              label: 'Barras flutuantes',
              trailing: _SettingsSwitch(
                value: preferences.floatingBars,
                onChanged: preferences.setFloatingBars,
              ),
            ),

            const SettingsGroupLabel('AJUDA E PRIVACIDADE'),
            SettingsRow(
              icon: Icons.mail_outline_rounded,
              label: 'Ajuda e contato',
              description: ExternalLinks.contactEmail,
              onTap: () => ExternalLinks.openContact(context),
            ),
            SettingsRow(
              icon: Icons.description_outlined,
              label: 'Termos de Uso',
              onTap: () => ExternalLinks.open(context, ExternalLinks.terms),
            ),
            SettingsRow(
              icon: Icons.privacy_tip_outlined,
              label: 'Política de Privacidade',
              onTap: () => ExternalLinks.open(context, ExternalLinks.privacy),
            ),

            const SizedBox(height: AppSpacing.xxl),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screen,
              ),
              child: VibesterPressable(
                onTap: _confirmarLogout,
                borderRadius: AppRadius.pillAll,
                child: Container(
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: AppRadius.pillAll,
                    border: Border.all(
                      color: colors.error.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    'Sair da conta',
                    style: context.typography.titleMedium.copyWith(
                      color: colors.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: AppSpacing.md),
            Center(
              child: VibesterPressable(
                borderRadius: AppRadius.pillAll,
                onTap: () =>
                    Navigator.pushNamed(context, AppRoutes.deleteAccount),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Text(
                    'Excluir conta',
                    style: context.typography.titleSmall.copyWith(
                      color: colors.textMuted,
                      decoration: TextDecoration.underline,
                      decorationColor: colors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// PREFERÊNCIAS: interruptor dos Ajustes.
///
/// É exatamente o `Switch` que a linha do modo escuro já usava — âmbar ligado,
/// superfície desligado —, tirado de lá para as linhas novas reaproveitarem
/// em vez de copiar as cores.
class _SettingsSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingsSwitch({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return Switch(
      value: value,
      activeThumbColor: colors.onAmbar,
      activeTrackColor: colors.ambar,
      inactiveTrackColor: colors.surface,
      onChanged: onChanged,
    );
  }
}