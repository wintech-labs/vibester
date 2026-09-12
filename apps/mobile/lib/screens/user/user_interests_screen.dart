import 'package:flutter/material.dart';
import 'package:mobile/models/user/interest_model.dart';
import 'package:mobile/routes/app_routes.dart';
import 'package:mobile/service/auth_storage_service.dart';
import 'package:mobile/service/user/interests_storage.dart';
import 'package:mobile/theme/app_spacing.dart';
import 'package:mobile/theme/theme_extensions.dart';
import 'package:mobile/widgets/buttons/vibester_button.dart';
import 'package:mobile/widgets/common/screen_header.dart';
import 'package:mobile/widgets/common/vibester_chip.dart';
import 'package:mobile/widgets/graffiti/grain.dart';

/// Seus interesses.
///
/// Mesma tela do fluxo de cadastro, agora com a escolha realmente sendo
/// guardada ([InterestsStorage]) — antes o toque só alternava um booleano na
/// lista em memória, que sumia ao fechar o app. Também deixou de ter um
/// `SizedBox(height: 300)` fixo empurrando o botão para baixo: a ação fica
/// ancorada no rodapé em qualquer tamanho de tela.
///
/// A tela serve dois contextos, e o que muda entre eles é só [noCadastro].
class UserInterestsScreen extends StatefulWidget {
  /// Esta tela é um passo do cadastro, e não uma edição avulsa.
  ///
  /// No cadastro ela é o último passo antes do onboarding: marca o onboarding
  /// como pendente e descarta a pilha inteira. Aberta pelas configurações, ela
  /// é só um formulário — salva e volta de onde veio.
  ///
  /// O padrão é `false` de propósito: o comportamento destrutivo precisa ser
  /// pedido, o inofensivo vem de graça. Um terceiro ponto de entrada que
  /// esqueça de configurar isso fecha normal, em vez de jogar o usuário no
  /// tutorial de boas-vindas.
  final bool noCadastro;

  const UserInterestsScreen({this.noCadastro = false, super.key});

  @override
  State<UserInterestsScreen> createState() => _UserInterestsScreenState();
}

class _UserInterestsScreenState extends State<UserInterestsScreen> {
  /// Seleção em edição, por id.
  ///
  /// Cópia local de propósito: `defaultInterests` é uma lista global e mutável
  /// que alimenta a régua de categorias da Home. Alternando os chips nela
  /// direto, sair sem confirmar já teria mudado a Home de quem não salvou
  /// nada — e só voltaria ao normal no próximo boot, quando o
  /// `InterestsStorage.restore` reaplicasse o disco por cima.
  late final Set<String> _selecionados = {
    for (final interest in defaultInterests)
      if (interest.selected) interest.id,
  };

  bool get noCadastro => widget.noCadastro;

  Future<void> _continuar() async {
    // Só aqui a escolha sai da tela: aplica na lista global e persiste.
    for (final interest in defaultInterests) {
      interest.selected = _selecionados.contains(interest.id);
    }
    await InterestsStorage.save(defaultInterests);
    if (!mounted) return;

    // Edição avulsa (configurações): os interesses já foram salvos, então a
    // tela só sai de cena. Sem isso, trocar um interesse pelas configurações
    // descartava a pilha e mandava um usuário antigo para o onboarding.
    if (!noCadastro) {
      Navigator.pop(context);
      return;
    }

    // Marca o onboarding como pendente antes de abri-lo, para que ele
    // reapareça se o app for fechado no meio.
    await AuthStorageService.marcarOnboardingPendente();
    if (!mounted) return;

    // Fim do fluxo de cadastro: remove register, email-confirm, profile-edit e
    // esta tela da pilha. O onboarding passa a ser a única rota; a home só vem
    // depois do "Começar".
    Navigator.pushNamedAndRemoveUntil(
      context,
      AppRoutes.onboarding,
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final selecionados = _selecionados.length;

    return Scaffold(
      backgroundColor: colors.noturno,
      body: Stack(
        children: [
          const Positioned.fill(child: Grain(opacity: 0.04, density: 0.4)),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ScreenHeader(
                  title: 'O que você\ncurte?',
                  eyebrow: 'SUA VIBE',
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.screen,
                    ),
                    child: Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.xs,
                      children: [
                        for (final interest in defaultInterests)
                          VibesterChip(
                            label: interest.label,
                            emoji: interest.emoji,
                            selected: _selecionados.contains(interest.id),
                            onTap: () => setState(() {
                              if (!_selecionados.remove(interest.id)) {
                                _selecionados.add(interest.id);
                              }
                            }),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.screen),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selecionados == 0
                            ? 'PODE ESCOLHER DEPOIS'
                            : '$selecionados SELECIONADAS',
                        style: context.typography.monoMicro.copyWith(
                          color: selecionados == 0
                              ? colors.textDisabled
                              : colors.ambar,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      VibesterButton(label: 'Continuar', onPressed: _continuar),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}