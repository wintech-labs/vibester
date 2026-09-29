import 'package:flutter/material.dart';
import 'package:mobile/models/notification/notification_model.dart';
import 'package:mobile/service/notification/notification_service.dart';
import 'package:mobile/utils/data_freshness.dart';

class NotificationProvider extends ChangeNotifier {
  final NotificationService _service = NotificationService();
  bool isLoading = false;
  String? error;

  List<NotificationModel> _notifications = [];
  DateTime? _lastFetchedAt;

  int unreadCount = 0;

  List<NotificationModel> get notifications => _notifications;

  /// Busca as notificações do usuário.
  ///
  /// Se já houver dados carregados e ainda dentro da janela de validade,
  /// não refaz a requisição — a menos que [force] seja true (pull-to-refresh).
  Future<void> fetchNotifications(String userId, {bool force = false}) async {
    if (_notifications.isNotEmpty && !force && !isDataStale(_lastFetchedAt)) {
      return;
    }

    isLoading = true;
    error = null;
    notifyListeners();

    try {
      _notifications = await _service.getNotifications(userId);
      _lastFetchedAt = DateTime.now();

      // O contador é a mesma informação vista por outro ângulo. Recalculá-lo
      // a partir da lista recém-chegada evita o estado em que o sino mostra
      // selo e a tela aberta diz "silêncio total".
      unreadCount = _notifications.where((n) => !n.lida).length;
    } catch (e) {
      // A mensagem na tela continua genérica — o usuário não tem o que fazer
      // com o detalhe —, mas o detalhe precisa existir em algum lugar: sem
      // isto, "deu erro" e "não há notificações" eram indistinguíveis até
      // para quem estava depurando.
      debugPrint('[notifications] fetchNotifications falhou: $e');
      error = 'Não foi possível carregar as notificações';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Atualiza só o contador de não vistas (badge), sem afetar a lista
  /// carregada. Chamado com frequência (boot do app, troca de aba, volta do
  /// segundo plano) já que é uma chamada barata, sem cache/staleness.
  Future<void> fetchUnreadCount(String userId) async {
    try {
      unreadCount = await _service.getUnreadCount(userId);
      notifyListeners();
    } catch (e) {
      // Mantém o valor atual em tela caso a atualização falhe — mas registra,
      // porque um contador que nunca sobe é exatamente o sintoma de uma falha
      // engolida aqui.
      debugPrint('[notifications] fetchUnreadCount falhou: $e');
    }
  }

  /// Marca todas as notificações como lidas no backend e zera o badge
  /// localmente, sem round-trip.
  ///
  /// A lista já carregada (`notifications`) continua intocada de propósito:
  /// é o que mantém a seção "novas" visível durante esta visita, em vez de
  /// tudo migrar para "já vistas" na frente do usuário.
  ///
  /// O que mudou é o cache: ele é invalidado aqui. Sem isso, reabrir a tela
  /// dentro da janela de 5 minutos devolvia a lista antiga em memória, com
  /// todo mundo ainda marcado como não lido — a tela dizia "novas" para
  /// notificações que o servidor já considerava vistas. Agora a próxima
  /// abertura busca de novo e mostra o estado real.
  Future<void> markAllRead(String userId) async {
    if (unreadCount == 0 && _notifications.every((n) => n.lida)) return;

    try {
      await _service.markAllRead(userId);
      unreadCount = 0;
      _lastFetchedAt = null;
      notifyListeners();
    } catch (e) {
      // Se falhar, o badge continua mostrando o valor anterior.
      debugPrint('[notifications] markAllRead falhou: $e');
    }
  }

  /// Obriga a próxima abertura da tela a buscar de novo, sem esperar a janela
  /// de 5 minutos. Usado quando o app sabe que chegou aviso novo — a remoção
  /// de um post pela moderação — e a lista em memória ainda não o tem.
  void markStale() {
    _lastFetchedAt = null;
  }

  /// Descarta tudo que pertence à sessão anterior.
  ///
  /// O provider vive no topo da árvore e sobrevive ao logout: sem esta
  /// limpeza, quem saísse e entrasse com outra conta via o selo e a lista do
  /// usuário anterior até a primeira busca terminar.
  void clear() {
    _notifications = [];
    _lastFetchedAt = null;
    unreadCount = 0;
    error = null;
    isLoading = false;
    notifyListeners();
  }
}
