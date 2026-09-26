import 'package:mobile/models/feed/feed_item_model.dart';
import 'package:mobile/models/media/post_media.dart';

class PublicationModel {
  final String? id;
  final String? authorId;
  final String autor;
  final String autorProfileImage;

  /// Capa do post (primeira foto, ou capa do primeiro vídeo).
  final String publicationImage;

  /// Toda a mídia do post, na ordem do carrossel.
  final List<PostMedia> media;
  final String description;
  final String? location;

  /// Id do estabelecimento marcado no post, par do nome em [location].
  ///
  /// LOCAL CLICÁVEL: o feed-service sempre mandou este id
  /// (`establishment_id`), e o `FeedItemModel` já o lia — mas ele se perdia
  /// aqui, na conversão para o modelo que o card desenha, que só guardava o
  /// nome. Sem o id não havia para onde levar o toque no local. Nulo em post
  /// sem local marcado e em post antigo que só tenha o nome.
  final String? establishmentId;
  final DateTime publicatedAt;
  final int likes;
  final bool isLiked;

  PublicationModel({
    this.id,
    this.authorId,
    required this.autor,
    required this.autorProfileImage,
    required this.publicationImage,
    this.media = const [],
    required this.description,
    this.location,
    this.establishmentId,
    required this.publicatedAt,
    this.likes = 0,
    this.isLiked = false,
  });

  PublicationModel copyWith({
    String? id,
    String? authorId,
    String? autor,
    String? autorProfileImage,
    String? publicationImage,
    List<PostMedia>? media,
    String? description,
    String? location,
    String? establishmentId,
    DateTime? publicatedAt,
    int? likes,
    bool? isLiked,
  }) {
    return PublicationModel(
      id: id ?? this.id,
      authorId: authorId ?? this.authorId,
      autor: autor ?? this.autor,
      autorProfileImage: autorProfileImage ?? this.autorProfileImage,
      publicationImage: publicationImage ?? this.publicationImage,
      media: media ?? this.media,
      description: description ?? this.description,
      location: location ?? this.location,
      establishmentId: establishmentId ?? this.establishmentId,
      publicatedAt: publicatedAt ?? this.publicatedAt,
      likes: likes ?? this.likes,
      isLiked: isLiked ?? this.isLiked,
    );
  }

  factory PublicationModel.fromFeedItem(FeedItemModel item) {
    return PublicationModel(
      id: item.itemId,
      authorId: item.authorId,
      autor: item.authorUsername ?? '',
      autorProfileImage: item.authorProfilePicture ?? '',
      publicationImage: item.media.isNotEmpty ? item.media.first.coverUrl : '',
      media: item.media,
      description: item.content ?? '',
      location: item.establishmentName,
      // LOCAL CLICÁVEL: repassa o id que o item de feed já trazia.
      establishmentId: item.establishmentId,
      publicatedAt: item.createdAt,
      likes: item.totalLikes,
      isLiked: item.isLiked,
    );
  }

  /// Post como o post-service devolve (`POST /post/posts` → 201): camelCase,
  /// ao contrário do item de feed, que é snake_case.
  factory PublicationModel.fromPost(Map<String, dynamic> json) {
    final media = PostMedia.listFromJson(
      json['media'],
      legacyImageUrls: json['imageUrls'],
    );
    return PublicationModel(
      id: json['postId'] as String?,
      authorId: json['userId'] as String?,
      autor: json['userUsername'] as String? ?? '',
      autorProfileImage: json['userProfilePicture'] as String? ?? '',
      publicationImage: media.isNotEmpty ? media.first.coverUrl : '',
      media: media,
      description: json['caption'] as String? ?? '',
      location: json['establishmentName'] as String?,
      // LOCAL CLICÁVEL: mesmo campo que o app envia ao criar o post. Se a
      // resposta não o devolver, o post recém-publicado mostra o local sem
      // toque até o próximo refresh, quando passa a vir pelo feed.
      establishmentId: json['establishmentId'] as String?,
      publicatedAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '')?.toLocal() ??
          DateTime.now(),
      likes: (json['totalLikes'] as num?)?.toInt() ?? 0,
    );
  }
}