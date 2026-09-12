import 'package:flutter/material.dart';
import 'package:mobile/models/media/media_item.dart';
import 'package:mobile/models/user/user_model.dart';
import 'package:mobile/providers/user/user_provider.dart';
import 'package:mobile/routes/app_routes.dart';
import 'package:mobile/service/user/interests_storage.dart';
import 'package:mobile/service/user/user_service.dart';
import 'package:mobile/theme/app_spacing.dart';
import 'package:mobile/theme/theme_extensions.dart';
import 'package:mobile/widgets/buttons/vibester_button.dart';
import 'package:mobile/widgets/cards/users/editing_avatar.dart';
import 'package:mobile/widgets/common/screen_header.dart';
import 'package:mobile/widgets/common/settings_row.dart';
import 'package:mobile/widgets/common/vibester_skeleton.dart';
import 'package:mobile/widgets/motion/vibester_pressable.dart';
import 'package:mobile/widgets/text-field/primary_text_field.dart';
import 'package:provider/provider.dart';

/// Informações pessoais.
///
/// Reorganizada em torno do que o backend realmente aceita alterar. Antes,
/// **oito** campos pareciam editáveis, mas só quatro (avatar, nome, usuário e
/// bio) chegavam a uma chamada de API: e-mail, telefone, data de nascimento,
/// cidade e interesses apenas escreviam no provider em memória, então o
/// usuário editava, via o valor mudar, fechava o app e perdia tudo — sem
/// nunca receber um aviso.
///
/// Agora os campos com API ficam num grupo editável, e os demais aparecem
/// como leitura, com uma nota explicando por quê. Interesses viraram um
/// atalho para a tela que de fato guarda a escolha.
///
/// A edição também mudou de forma: era um `Dialog` com um botão verde
/// "Confirmar" e um vermelho "Cancelar" lado a lado, ambos do mesmo tamanho —
/// duas ações de peso igual, sendo que uma delas destrói o que foi digitado.
/// Virou uma folha inferior com um campo e uma ação principal.
class PersonalInformationSettingsScreen extends StatefulWidget {
  const PersonalInformationSettingsScreen({super.key});

  @override
  State<PersonalInformationSettingsScreen> createState() =>
      _PersonalInformationSettingsScreenState();
}

class _PersonalInformationSettingsScreenState
    extends State<PersonalInformationSettingsScreen> {
  final _userService = UserService();
  bool _isLoadingAvatar = false;

  void _atualizarProviderComResposta(Map<String, dynamic> response) {
    final tokenAtual = context.read<UserProvider>().user?.token;
    final accountId = context.read<UserProvider>().user?.accountId ?? '';
    final usuarioAtualizado = UserModel.fromProfileJson(
      response,
      accountId: accountId,
      token: tokenAtual,
    );
    context.read<UserProvider>().setUser(usuarioAtualizado);
  }

  void _mostrarErro(String mensagem) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(mensagem)));
  }

  /// Devolve se a foto subiu — o `EditableAvatar` volta para a anterior
  /// quando não sobe, em vez de mostrar uma foto que ninguém mais vai ver.
  Future<bool> _salvarAvatar(MediaItem image) async {
    final user = context.read<UserProvider>().user;
    final accountId = user?.accountId ?? '';
    final tokenAtual = user?.token;
    if (accountId.isEmpty) return false;

    setState(() => _isLoadingAvatar = true);

    try {
      final response = await _userService.updateAvatar(
        accountId: accountId,
        image: image,
      );
      if (!mounted) return true;
      final usuarioAtualizado = UserModel.fromProfileJson(
        response,
        accountId: accountId,
        token: tokenAtual,
      );
      context.read<UserProvider>().setUser(usuarioAtualizado);
      return true;
    } catch (e) {
      debugPrint('Falha ao atualizar avatar: $e');
      _mostrarErro(
        e is Exception
            ? e.toString().replaceFirst('Exception: ', '')
            : 'Não foi possível atualizar a foto.',
      );
      return false;
    } finally {
      if (mounted) setState(() => _isLoadingAvatar = false);
    }
  }

  Future<void> _salvarNome(String novoNome) async {
    final user = context.read<UserProvider>().user;
    try {
      final response = await _userService.updateName(
        accountId: user?.accountId ?? '',
        name: novoNome,
        username: user?.nomeUsuario ?? '',
      );
      if (!mounted) return;
      _atualizarProviderComResposta(response);
    } catch (e) {
      _mostrarErro(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _salvarUsername(String novoUsername) async {
    final user = context.read<UserProvider>().user;
    var usernameFormatado = novoUsername.replaceAll(' ', '');
    if (!usernameFormatado.startsWith('@')) {
      usernameFormatado = '@$usernameFormatado';
    }
    try {
      final response = await _userService.updateName(
        accountId: user?.accountId ?? '',
        name: user?.nome ?? '',
        username: usernameFormatado,
      );
      if (!mounted) return;
      _atualizarProviderComResposta(response);
    } catch (e) {
      _mostrarErro(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _salvarBio(String novaBio) async {
    final user = context.read<UserProvider>().user;
    try {
      final response = await _userService.updateBio(
        accountId: user?.accountId ?? '',
        bio: novaBio,
      );
      if (!mounted) return;
      _atualizarProviderComResposta(response);
    } catch (e) {
      _mostrarErro(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _editarCampo({
    required String titulo,
    required String valorAtual,
    required Future<void> Function(String) onSalvar,
    int? maxCaracteres,
    int maxLines = 1,
  }) async {
    final novoValor = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _EditSheet(
        titulo: titulo,
        valorAtual: valorAtual,
        maxCaracteres: maxCaracteres,
        maxLines: maxLines,
      ),
    );

    if (novoValor == null || novoValor == valorAtual) return;
    await onSalvar(novoValor);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final user = context.watch<UserProvider>().user;

    if (user == null) {
      return Scaffold(
        backgroundColor: colors.noturno,
        body: const SafeArea(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.screen),
            child: VibesterSkeletonLines(lines: 4, spacing: AppSpacing.lg),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: colors.noturno,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.huge),
          children: [
            const ScreenHeader(
              title: 'Seus dados',
              eyebrow: 'INFORMAÇÕES PESSOAIS',
              bottomSpacing: AppSpacing.md,
            ),

            Center(
              child: Column(
                children: [
                  EditableAvatar(
                    radius: 56,
                    imageUrl: user.fotoPerfil.isNotEmpty
                        ? user.fotoPerfil
                        : null,
                    onImageChanged: _salvarAvatar,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    _isLoadingAvatar ? 'ENVIANDO…' : 'TOCA PRA TROCAR A FOTO',
                    style: context.typography.monoMicro.copyWith(
                      color: _isLoadingAvatar
                          ? colors.ambar
                          : colors.textDisabled,
                    ),
                  ),
                ],
              ),
            ),

            const SettingsGroupLabel('PERFIL'),
            SettingsRow(
              icon: Icons.badge_outlined,
              label: 'Nome',
              description: user.nome.isEmpty ? '—' : user.nome,
              onTap: () => _editarCampo(
                titulo: 'Nome',
                valorAtual: user.nome,
                onSalvar: _salvarNome,
                maxCaracteres: 30,
              ),
            ),
            SettingsRow(
              icon: Icons.alternate_email_rounded,
              label: 'Nome de usuário',
              description: user.nomeUsuario.isEmpty ? '—' : user.nomeUsuario,
              onTap: () => _editarCampo(
                titulo: 'Nome de usuário',
                valorAtual: user.nomeUsuario,
                onSalvar: _salvarUsername,
                maxCaracteres: 30,
              ),
            ),
            SettingsRow(
              icon: Icons.notes_rounded,
              label: 'Bio',
              description: user.bio.isEmpty ? '—' : user.bio,
              onTap: () => _editarCampo(
                titulo: 'Bio',
                valorAtual: user.bio,
                onSalvar: _salvarBio,
                maxCaracteres: 150,
                maxLines: 3,
              ),
            ),
            SettingsRow(
              icon: Icons.favorite_border_rounded,
              label: 'Seus interesses',
              description: InterestsStorage.selected.isEmpty
                  ? 'Nenhum escolhido'
                  : InterestsStorage.selected.map((i) => i.label).join(', '),
              // A descrição acima lê `InterestsStorage` no build, e voltar de
              // uma rota não reconstrói a de baixo: sem este setState a linha
              // continuaria mostrando a lista antiga até a tela ser refeita
              // por outro motivo.
              onTap: () async {
                await Navigator.pushNamed(context, AppRoutes.userInterests);
                if (!mounted) return;
                setState(() {});
              },
            ),

            const SettingsGroupLabel('CONTA'),
            _ReadOnlyRow(label: 'E-mail', value: user.email),
            _ReadOnlyRow(label: 'Telefone', value: user.telefone),
            _ReadOnlyRow(
              label: 'Data de nascimento',
              value: user.dataNascimento,
            ),
            _ReadOnlyRow(label: 'Cidade', value: user.cidade),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screen,
                AppSpacing.md,
                AppSpacing.screen,
                0,
              ),
              child: Text(
                'Esses dados ainda não podem ser alterados pelo app. Fale com '
                'o suporte se algum estiver errado.',
                style: context.typography.bodySmall.copyWith(
                  color: colors.textDisabled,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Linha de leitura: mesma anatomia da linha de ajuste, sem afordância de
/// toque — sem seta, sem ripple, sem promessa de edição.
class _ReadOnlyRow extends StatelessWidget {
  final String label;
  final String value;

  const _ReadOnlyRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screen,
        vertical: AppSpacing.lg,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.hairline)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: context.typography.titleMedium.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Text(
            value.isEmpty ? '—' : value,
            style: context.typography.monoSmall.copyWith(
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Folha de edição de um campo. Uma ação principal ("Salvar"); cancelar é
/// fechar a folha, como em qualquer bottom sheet.
class _EditSheet extends StatefulWidget {
  final String titulo;
  final String valorAtual;
  final int? maxCaracteres;
  final int maxLines;

  const _EditSheet({
    required this.titulo,
    required this.valorAtual,
    required this.maxCaracteres,
    required this.maxLines,
  });

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final _controller = TextEditingController(text: widget.valorAtual);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screen,
            AppSpacing.sm,
            AppSpacing.screen,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PrimaryTextField(
                controller: _controller,
                label: widget.titulo,
                maxLines: widget.maxLines,
                textInputAction: widget.maxLines > 1
                    ? TextInputAction.newline
                    : TextInputAction.done,
                onSubmitted: (value) => Navigator.pop(context, value.trim()),
              ),
              if (widget.maxCaracteres != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    'ATÉ ${widget.maxCaracteres} CARACTERES',
                    style: context.typography.monoMicro.copyWith(
                      color: context.colors.textDisabled,
                    ),
                  ),
                ),
              const SizedBox(height: AppSpacing.lg),
              VibesterButton(
                label: 'Salvar',
                onPressed: () =>
                    Navigator.pop(context, _controller.text.trim()),
              ),
              const SizedBox(height: AppSpacing.sm),
              Center(
                child: VibesterPressable(
                  onTap: () => Navigator.pop(context),
                  borderRadius: AppRadius.pillAll,
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Text(
                      'CANCELAR',
                      style: context.typography.monoMicro.copyWith(
                        color: context.colors.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}