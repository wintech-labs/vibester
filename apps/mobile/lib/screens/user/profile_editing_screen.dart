import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/models/media/media_item.dart';
import 'package:mobile/models/user/user_model.dart';
import 'package:mobile/providers/user/user_provider.dart';
import 'package:mobile/routes/app_routes.dart';
import 'package:mobile/service/user/user_service.dart';
import 'package:mobile/theme/app_spacing.dart';
import 'package:mobile/theme/theme_extensions.dart';
import 'package:mobile/widgets/buttons/vibester_button.dart';
import 'package:mobile/widgets/cards/users/editing_avatar.dart';
import 'package:mobile/widgets/common/screen_header.dart';
import 'package:mobile/widgets/graffiti/grain.dart';
import 'package:mobile/widgets/text-field/primary_text_field.dart';
import 'package:provider/provider.dart';

class ProfileEditingScreen extends StatefulWidget {
  const ProfileEditingScreen({super.key});

  @override
  State<ProfileEditingScreen> createState() => _ProfileEditingScreenState();
}

class _ProfileEditingScreenState extends State<ProfileEditingScreen> {
  final TextEditingController _nomeController = TextEditingController();
  final TextEditingController _bioController = TextEditingController();

  final _formKey = GlobalKey<FormState>();
  final _userService = UserService();
  bool _isLoading = false;

  @override
  void dispose() {
    _nomeController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  /// Sobe a foto escolhida assim que ela é escolhida — o passo seguinte do
  /// cadastro não depende dela, então não faz sentido segurar o upload até o
  /// "Continuar". Devolve se subiu, para o avatar voltar à foto anterior
  /// quando não sobe.
  Future<bool> _salvarAvatar(MediaItem image) async {
    final user = context.read<UserProvider>().user;
    final accountId = user?.accountId ?? '';
    if (accountId.isEmpty) return false;

    try {
      final response = await _userService.updateAvatar(
        accountId: accountId,
        image: image,
      );
      if (!mounted) return true;
      context.read<UserProvider>().setUser(
        UserModel.fromProfileJson(
          response,
          accountId: accountId,
          token: user?.token,
        ),
      );
      return true;
    } catch (e) {
      debugPrint('Falha ao enviar avatar: $e');
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e is Exception
                ? e.toString().replaceFirst('Exception: ', '')
                : 'Não foi possível enviar a foto agora',
          ),
        ),
      );
      return false;
    }
  }

  Future<void> _salvarPerfil() async {
    if (!_formKey.currentState!.validate()) return;

    final userAtual = context.read<UserProvider>().user;
    final accountId = userAtual?.accountId ?? '';
    final tokenAtual = userAtual?.token;
    final nome = _nomeController.text.trim();
    final bio = _bioController.text.trim();

    setState(() => _isLoading = true);

    try {
      // UpDate Nome
      final nameResponse = await _userService.updateName(
        accountId: accountId,
        name: nome,
        username: userAtual?.nomeUsuario ?? '',
      );

      var usuarioAtualizado = UserModel.fromProfileJson(
        nameResponse,
        accountId: accountId,
        token: tokenAtual,
      );

      if (!mounted) return;
      context.read<UserProvider>().setUser(usuarioAtualizado);

      // UpDate bio
      final bioResponse = await _userService.updateBio(
        accountId: accountId,
        bio: bio,
      );

      usuarioAtualizado = UserModel.fromProfileJson(
        bioResponse,
        accountId: accountId,
        token: tokenAtual,
      );

      if (!mounted) return;
      context.read<UserProvider>().setUser(usuarioAtualizado);

      // Esta tela só existe dentro do cadastro hoje, então os interesses que
      // ela abre são o passo seguinte do fluxo, não uma edição. No dia em que
      // existir um "editar perfil" a partir do perfil, este `true` precisa
      // virar um flag desta tela também.
      Navigator.pushNamed(
        context,
        AppRoutes.userInterests,
        arguments: true,
      );
    } catch (e) {
      debugPrint(e.toString());

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Não foi possível atualizar o perfil. Tente novamente.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final user = context.watch<UserProvider>().user;

    return Scaffold(
      backgroundColor: colors.noturno,
      body: Stack(
        children: [
          const Positioned.fill(child: Grain(opacity: 0.04, density: 0.4)),
          SafeArea(
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                children: [
                  const ScreenHeader(
                    title: 'Monta seu\nperfil',
                    eyebrow: 'COMO VÃO TE VER',
                    showBack: false,
                  ),
                  Center(
                    child: EditableAvatar(
                      radius: 56,
                      imageUrl: (user?.fotoPerfil.isNotEmpty ?? false)
                          ? user!.fotoPerfil
                          : null,
                      onImageChanged: _salvarAvatar,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Center(
                    child: Text(
                      'ESCOLHE UMA FOTO',
                      style: context.typography.monoMicro.copyWith(
                        color: colors.textDisabled,
                      ),
                    ),
                  ),

                  const SizedBox(height: AppSpacing.xxl),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.screen,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PrimaryTextField(
                          controller: _nomeController,
                          label: 'Como te chamam',
                          icon: Icons.person_outline_rounded,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(30),
                          ],
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? 'Informe um nome'
                              : null,
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        PrimaryTextField(
                          controller: _bioController,
                          label: 'Bio',
                          hint: 'Uma linha sobre você',
                          icon: Icons.notes_rounded,
                          maxLines: 3,
                          textInputAction: TextInputAction.newline,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(150),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.xl),
                        VibesterButton(
                          label: 'Continuar',
                          state: _isLoading
                              ? VibesterButtonState.loading
                              : VibesterButtonState.idle,
                          onPressed: _salvarPerfil,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}