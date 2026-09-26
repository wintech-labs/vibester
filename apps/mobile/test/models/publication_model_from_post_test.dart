import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/feed/feed_item_model.dart';
import 'package:mobile/models/feed/publication_model.dart';
import 'package:mobile/models/media/media_item.dart';

/// Resposta do `POST /post/posts` (camelCase), que vira o post exibido no
/// topo do feed logo depois de publicar.
void main() {
  test('lê o post criado pelo post-service', () {
    final post = PublicationModel.fromPost({
      'postId': 'p-1',
      'userId': 'u-1',
      'userUsername': 'ana',
      'userProfilePicture': 'https://cdn/avatar.jpg',
      'media': [
        {
          'url': 'https://cdn/v.mp4',
          'type': 'VIDEO',
          'thumbnailUrl': 'https://cdn/t.jpg',
        },
        {'url': 'https://cdn/f.jpg', 'type': 'IMAGE'},
      ],
      'imageUrls': ['https://cdn/f.jpg'],
      'caption': 'rolê',
      'establishmentId': 'est-9',
      'establishmentName': 'Bar do Zé',
      'totalLikes': 0,
      'createdAt': '2026-09-16T22:00:00.000Z',
    });

    expect(post.id, 'p-1');
    expect(post.authorId, 'u-1');
    expect(post.autor, 'ana');
    expect(post.media.map((m) => m.kind), [MediaKind.video, MediaKind.image]);
    expect(post.publicationImage, 'https://cdn/t.jpg');
    expect(post.description, 'rolê');
    expect(post.location, 'Bar do Zé');
    expect(post.establishmentId, 'est-9');
    expect(post.publicatedAt.toUtc(), DateTime.utc(2026, 9, 16, 22));
    expect(post.isLiked, isFalse);
  });

  test('campos opcionais ausentes não quebram', () {
    final post = PublicationModel.fromPost({'postId': 'p-1'});

    expect(post.autor, '');
    expect(post.media, isEmpty);
    expect(post.location, isNull);
    expect(post.establishmentId, isNull);
  });

  // LOCAL CLICÁVEL: o id do estabelecimento vinha no item de feed, mas se
  // perdia na conversão para o modelo do card.
  test('item de feed leva o id do estabelecimento para o card', () {
    final item = FeedItemModel.fromJson({
      'item_id': 'p-2',
      'item_type': 'USER_POST',
      'user_id': 'u-1',
      'created_at': '2026-09-16T22:00:00.000Z',
      'updated_at': '2026-09-16T22:00:00.000Z',
      'author_id': 'u-2',
      'author_username': 'ana',
      'establishment_id': 'est-9',
      'establishment_name': 'Bar do Zé',
    });

    final post = PublicationModel.fromFeedItem(item);

    expect(post.location, 'Bar do Zé');
    expect(post.establishmentId, 'est-9');
  });
}