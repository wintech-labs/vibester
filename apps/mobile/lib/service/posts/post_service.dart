import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:mobile/models/feed/publication_model.dart';
import 'package:mobile/models/media/media_item.dart';
import 'package:mobile/service/api_client.dart';
import 'package:mobile/service/api_endpoints.dart';
import 'package:mobile/service/api_error.dart';
import 'package:mobile/service/media_upload_service.dart';

/// O que a moderação de imagem decidiu sobre um post já publicado.
enum PostModerationStatus {
  /// O post continua no ar.
  visible,

  /// O post foi ocultado (`isDeleted`) ou já não existe.
  removed,

  /// Não deu para saber agora (rede, 5xx). Não é veredito.
  unknown,
}

class PostService {
  final MediaUploadService _mediaUpload = MediaUploadService();

  /// Sobe as mídias ao R2. Separado de [createPost] para o composer guardar o
  /// resultado: quando o post-service recusa o texto (422), a pessoa corrige a
  /// legenda e publica de novo sem reenviar as fotos.
  Future<List<UploadedMedia>> uploadMedia({
    required String userId,
    required List<MediaItem> media,
  }) => _mediaUpload.upload(userId: userId, items: media);

  /// Devolve o post criado, para o feed exibi-lo na hora — ou `null` se a
  /// resposta não trouxer o corpo esperado (o post foi criado mesmo assim).
  ///
  /// O post-service valida o texto no post-validation-service antes de gravar
  /// e responde 422 com os motivos já em pt-BR, que chegam à tela pelo
  /// `apiErrorMessage`. As fotos não são checadas aqui: a moderação de imagem
  /// roda depois de publicado (ver [moderationStatus]).
  Future<PublicationModel?> createPost({
    required String userId,
    required String userUsername,
    required String userProfilePicture,
    required bool userVerified,
    required String caption,
    required List<UploadedMedia> media,
    String? establishmentId,
    String? establishmentName,
    String? establishmentLogo,
    String? establishmentCategory,
  }) async {
    try {
      final response = await ApiClient.dio.post(
        ApiEndpoints.posts(),
        data: {
          'userId': userId,
          // O post-service valida `userProfilePicture`/`establishmentLogo`
          // como URI e `userUsername` com tamanho mínimo: string vazia (usuário
          // sem avatar, lugar sem foto) derrubava a publicação com 400. Campo
          // sem valor não vai no corpo.
          'userUsername': ?_nonEmpty(userUsername),
          'userProfilePicture': ?_nonEmpty(userProfilePicture),
          'userVerified': userVerified,
          'caption': caption,
          'media': [for (final item in media) item.toJson()],
          'establishmentId': ?_nonEmpty(establishmentId),
          'establishmentName': ?_nonEmpty(establishmentName),
          'establishmentLogo': ?_nonEmpty(establishmentLogo),
          'establishmentCategory': ?_nonEmpty(establishmentCategory),
        },
      );
      return _parseCreated(response.data);
    } on DioException catch (e) {
      throw Exception(apiErrorMessage(e, 'Erro ao publicar post'));
    }
  }

  Future<void> likePost({
    required String postId,
    required String userId,
  }) async {
    try {
      await ApiClient.dio.post(
        ApiEndpoints.likePost(postId),
        data: {'userId': userId},
      );
    } on DioException catch (e) {
      throw Exception(apiErrorMessage(e, 'Erro ao curtir post'));
    }
  }

  Future<void> unlikePost({
    required String postId,
    required String userId,
  }) async {
    try {
      await ApiClient.dio.delete(
        ApiEndpoints.likePost(postId),
        data: {'userId': userId},
      );
    } on DioException catch (e) {
      throw Exception(apiErrorMessage(e, 'Erro ao descurtir post'));
    }
  }

  /// Soft delete no post-service. Só o dono consegue: o serviço compara o
  /// `userId` do corpo com o autor e responde 403 para qualquer outro.
  /// 404 conta como sucesso — o post já não existe, que é o estado desejado
  /// (ex.: exclusão repetida por um toque duplo ou outra tela).
  Future<void> deletePost({
    required String postId,
    required String userId,
  }) async {
    try {
      await ApiClient.dio.delete(
        ApiEndpoints.post(postId),
        data: {'userId': userId},
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return;
      throw Exception(apiErrorMessage(e, 'Erro ao excluir post'));
    }
  }

  /// Estado do post depois da moderação de imagem.
  ///
  /// A checagem de nudez e de violência gráfica roda no worker do
  /// post-validation-service **depois** do `post.created`. Quando ela pede
  /// ocultação, o post-service marca o post `isDeleted` (e invalida o cache de
  /// `GET /posts/:id`). Sem esta consulta, o post removido continuava no feed
  /// do próprio autor até o próximo refresh, como se tivesse sido aprovado.
  Future<PostModerationStatus> moderationStatus(String postId) async {
    try {
      final response = await ApiClient.dio.get(ApiEndpoints.post(postId));
      final body = response.data;
      if (body is Map && body['isDeleted'] == true) {
        return PostModerationStatus.removed;
      }
      return PostModerationStatus.visible;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return PostModerationStatus.removed;
      debugPrint('Falha ao consultar a moderação do post $postId: $e');
      return PostModerationStatus.unknown;
    }
  }

  /// O post já existe quando isto roda: corpo inesperado não pode virar erro
  /// na tela, senão a pessoa tenta de novo e publica duas vezes.
  PublicationModel? _parseCreated(Object? body) {
    if (body is! Map<String, dynamic> || body['postId'] is! String) return null;
    try {
      return PublicationModel.fromPost(body);
    } catch (e) {
      debugPrint('Post criado, mas a resposta não pôde ser lida: $e');
      return null;
    }
  }

  String? _nonEmpty(String? value) =>
      value == null || value.trim().isEmpty ? null : value;
}
