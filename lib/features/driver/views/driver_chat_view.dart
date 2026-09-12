import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'dart:async';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_models.dart';

class DriverChatView extends StatefulWidget {
  const DriverChatView({required this.rideId, super.key});
  final String rideId;
  @override
  State<DriverChatView> createState() => _DriverChatViewState();
}

class _DriverChatViewState extends State<DriverChatView> {
  final _input = TextEditingController();
  final _messages = <Map<String, Object?>>[];
  bool _loading = true;
  bool _sending = false;
  Timer? _polling;
  ApiClient get _api => Get.find<ApiClient>();

  @override
  void initState() {
    super.initState();
    _load();
    _polling = Timer.periodic(const Duration(seconds: 4), (_) => _load());
  }

  Future<void> _load() async {
    try {
      final result = await _api.execute<List<Map<String, Object?>>>(
          model: 'RideMessageModel',
          operation: 'list',
          data: <String, Object?>{'rideId': widget.rideId},
          parse: (json) => json is List
              ? json
                  .whereType<Map>()
                  .map((x) => Map<String, Object?>.from(x))
                  .toList()
              : <Map<String, Object?>>[]);
      if (result is ApiSuccess<List<Map<String, Object?>>>) {
        final known = _messages.map((item) => '${item['id']}').toSet();
        final incoming = result.data.where((item) => !known.contains('${item['id']}'));
        if (mounted) setState(() => _messages.addAll(incoming));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
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
            'messageType': 'Text'
          },
          parse: (json) => json is Map
              ? Map<String, Object?>.from(json)
              : <String, Object?>{});
      if (result is ApiSuccess<Map<String, Object?>>)
        setState(() {
          _messages.add(result.data);
          _input.clear();
        });
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
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: _messages.isEmpty
                        ? ListView(children: const <Widget>[
                            Padding(
                                padding: EdgeInsets.only(top: 96),
                                child: Center(
                                    child: Text('ابدأ المحادثة مع العميل.')))
                          ])
                        : ListView.builder(
                            padding: const EdgeInsets.all(12),
                            itemCount: _messages.length,
                            itemBuilder: (_, i) {
                              final m = _messages[i];
                              return Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Card(
                                      child: Padding(
                                          padding: const EdgeInsets.all(10),
                                          child:
                                              Text('${m['content'] ?? ''}'))));
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
                            decoration:
                                const InputDecoration(hintText: 'اكتب رسالة'))),
                    IconButton(
                        onPressed: _sending ? null : _send,
                        icon: const Icon(Icons.send_rounded))
                  ]))),
        ]),
      );
  @override
  void dispose() {
    _polling?.cancel();
    _input.dispose();
    super.dispose();
  }
}
