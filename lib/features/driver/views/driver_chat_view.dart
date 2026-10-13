import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_models.dart';
import '../../../core/realtime/tracking_hub_service.dart';
import '../../../core/services/auth_session_service.dart';

class DriverChatView extends StatefulWidget {
  const DriverChatView({required this.rideId, super.key});

  final String rideId;

  @override
  State<DriverChatView> createState() => _DriverChatViewState();
}

class _DriverChatViewState extends State<DriverChatView> {
  static const int _pageSize = 50;

  final _input = TextEditingController();
  final _scrollController = ScrollController();
  final _messages = <Map<String, Object?>>[];
  bool _loading = true;
  bool _loadingOlder = false;
  bool _hasOlderMessages = false;
  bool _sending = false;
  bool _latestLoadInFlight = false;
  StreamSubscription<TrackingHubEvent>? _eventSubscription;
  StreamSubscription<void>? _connectionSubscription;

  ApiClient get _api => Get.find<ApiClient>();
  AuthSessionService get _session => Get.find<AuthSessionService>();
  TrackingHubService get _hub => Get.find<TrackingHubService>();

  @override
  void initState() {
    super.initState();
    _eventSubscription = _hub.events.listen(_handleHubEvent);
    _connectionSubscription = _hub.connectionRestored.listen((_) {
      unawaited(_load());
    });
    unawaited(_load());
  }

  Future<void> _load({bool older = false}) async {
    if (_latestLoadInFlight || (older && _loadingOlder)) return;
    if (older && _messages.isEmpty) return;
    if (older) {
      _loadingOlder = true;
    } else {
      _latestLoadInFlight = true;
      if (_messages.isEmpty) _loading = true;
    }
    final shouldScrollToBottom = !older &&
        (_messages.isEmpty ||
            !_scrollController.hasClients ||
            _scrollController.position.maxScrollExtent -
                    _scrollController.position.pixels <=
                120);
    if (mounted) setState(() {});
    try {
      final data = <String, Object?>{
        'rideId': widget.rideId,
        'pageSize': _pageSize,
      };
      if (older) {
        final cursor = _messages.first;
        data['beforeId'] = cursor['id'];
        data['beforeCreatedAtUtc'] = cursor['createdAtUtc'];
      }
      final result = await _api.execute<List<Map<String, Object?>>>(
        model: 'RideMessageModel',
        operation: 'list',
        data: data,
        parse: (json) => json is List
            ? json
                .whereType<Map<Object?, Object?>>()
                .map((item) => Map<String, Object?>.from(item))
                .toList()
            : <Map<String, Object?>>[],
      );
      if (result is ApiSuccess<List<Map<String, Object?>>>) {
        if (older) {
          _mergeMessages(result.data);
          _hasOlderMessages = result.data.length == _pageSize;
        } else {
          _mergeMessages(result.data, scrollToBottom: shouldScrollToBottom);
          if (!_hasOlderMessages) {
            _hasOlderMessages = result.data.length == _pageSize;
          }
        }
      }
    } catch (_) {
      if (mounted) {
        Get.snackbar('تعذر تحميل المحادثة', 'تحقق من الاتصال وحاول مجدداً.');
      }
    } finally {
      if (older) {
        _loadingOlder = false;
      } else {
        _latestLoadInFlight = false;
        _loading = false;
      }
      if (mounted) setState(() {});
    }
  }

  void _handleHubEvent(TrackingHubEvent event) {
    if (event.name != 'rideMessageCreated' ||
        '${event.payload['rideId'] ?? ''}' != widget.rideId) {
      return;
    }
    if (mounted) {
      final shouldScrollToBottom = _messages.isEmpty ||
          !_scrollController.hasClients ||
          _scrollController.position.maxScrollExtent -
                  _scrollController.position.pixels <=
              120;
      setState(() => _mergeMessages(<Map<String, Object?>>[event.payload],
          scrollToBottom: shouldScrollToBottom));
    }
  }

  void _mergeMessages(
    Iterable<Map<String, Object?>> incoming, {
    bool scrollToBottom = false,
  }) {
    final byId = <String, Map<String, Object?>>{
      for (final message in _messages) '${message['id']}': message,
    };
    for (final message in incoming) {
      byId['${message['id']}'] = Map<String, Object?>.from(message);
    }
    final merged = byId.values.toList()
      ..sort((left, right) {
        final leftTime = DateTime.tryParse('${left['createdAtUtc'] ?? ''}') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final rightTime = DateTime.tryParse('${right['createdAtUtc'] ?? ''}') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final timeOrder = leftTime.compareTo(rightTime);
        if (timeOrder != 0) return timeOrder;
        return (int.tryParse('${left['id']}') ?? 0)
            .compareTo(int.tryParse('${right['id']}') ?? 0);
      });
    _messages
      ..clear()
      ..addAll(merged);
    if (scrollToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      });
    }
  }

  Future<void> _send() async {
    final content = _input.text.trim();
    if (content.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final result = await _api.execute<Map<String, Object?>>(
        model: 'RideMessageModel',
        operation: 'add',
        data: <String, Object?>{
          'rideId': widget.rideId,
          'content': content,
          'messageType': 'Text',
        },
        parse: (json) =>
            json is Map ? Map<String, Object?>.from(json) : <String, Object?>{},
      );
      if (result is ApiSuccess<Map<String, Object?>>) {
        _mergeMessages(<Map<String, Object?>>[result.data],
            scrollToBottom: true);
        _input.clear();
      } else {
        Get.snackbar('تعذر إرسال الرسالة', 'حاول مرة أخرى.');
      }
    } catch (_) {
      Get.snackbar('تعذر إرسال الرسالة', 'تحقق من الاتصال وحالة الرحلة.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('محادثة العميل')),
        body: Column(children: <Widget>[
          Expanded(
            child: _loading && _messages.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: _messages.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: const <Widget>[
                              Padding(
                                padding: EdgeInsets.only(top: 96),
                                child: Center(
                                  child: Text('ابدأ المحادثة مع العميل.'),
                                ),
                              ),
                            ],
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(12),
                            itemCount:
                                _messages.length + (_hasOlderMessages ? 1 : 0),
                            itemBuilder: (_, index) {
                              if (_hasOlderMessages && index == 0) {
                                return Center(
                                  child: TextButton.icon(
                                    onPressed: _loadingOlder
                                        ? null
                                        : () => _load(older: true),
                                    icon: _loadingOlder
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2),
                                          )
                                        : const Icon(Icons.history_rounded),
                                    label: const Text('تحميل رسائل أقدم'),
                                  ),
                                );
                              }
                              final messageIndex =
                                  _hasOlderMessages ? index - 1 : index;
                              final message = _messages[messageIndex];
                              final senderId =
                                  int.tryParse('${message['senderId'] ?? ''}');
                              final isDriverMessage = senderId != null &&
                                  senderId == _session.currentUserId.value;
                              return Align(
                                alignment: isDriverMessage
                                    ? AlignmentDirectional.centerStart
                                    : AlignmentDirectional.centerEnd,
                                child: Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Text('${message['content'] ?? ''}'),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(hintText: 'اكتب رسالة'),
                  ),
                ),
                IconButton(
                  onPressed: _sending ? null : _send,
                  icon: const Icon(Icons.send_rounded),
                ),
              ]),
            ),
          ),
        ]),
      );

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    _input.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}
