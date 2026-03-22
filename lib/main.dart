import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MainApp());
}

class PlatformInfo {
  final String id;
  final int currentPriority;
  final int queueSize;
  final bool isPlaying;

  PlatformInfo({
    required this.id,
    required this.currentPriority,
    required this.queueSize,
    required this.isPlaying,
  });

  factory PlatformInfo.fromJson(String id, Map<String, dynamic> json) {
    return PlatformInfo(
      id: id,
      currentPriority: json['current_priority'] ?? -1,
      queueSize: json['queue_size'] ?? 0,
      isPlaying: json['is_playing'] ?? false,
    );
  }
}

class BroadcastPreset {
  final String name;
  final String component;
  final int priority;
  final String stateJson;

  const BroadcastPreset({
    required this.name,
    required this.component,
    required this.priority,
    required this.stateJson,
  });

  BroadcastPreset copyWith({
    String? name,
    String? component,
    int? priority,
    String? stateJson,
  }) {
    return BroadcastPreset(
      name: name ?? this.name,
      component: component ?? this.component,
      priority: priority ?? this.priority,
      stateJson: stateJson ?? this.stateJson,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'component': component,
      'priority': priority,
      'stateJson': stateJson,
    };
  }

  factory BroadcastPreset.fromJson(Map<String, dynamic> json) {
    return BroadcastPreset(
      name: (json['name'] ?? '').toString(),
      component: (json['component'] ?? 'main').toString(),
      priority: json['priority'] is int
          ? json['priority'] as int
          : int.tryParse((json['priority'] ?? '0').toString()) ?? 0,
      stateJson: (json['stateJson'] ?? '{}').toString(),
    );
  }
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Train Station Player Helper',
      theme: ThemeData(primarySwatch: Colors.blue, brightness: Brightness.dark),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const String _presetStorageKey = 'broadcast_presets_v1';
  static const String _serverAddressStorageKey = 'server_address_v1';
  static const BroadcastPreset _defaultPreset = BroadcastPreset(
    name: 'Default',
    component: 'main',
    priority: 0,
    stateJson:
        '{\n  "platform": "{platform}",\n  "dest": "station_a",\n  "type": "local"\n}',
  );

  final TextEditingController _serverAddressController =
      TextEditingController();
  List<PlatformInfo> _platforms = [];
  final List<BroadcastPreset> _presets = [_defaultPreset];
  Timer? _pollingTimer;
  String _statusMessage = 'サーバーアドレスを入力してください';
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    _serverAddressController.text = 'http://localhost:8000';
    _loadPersistedSettings();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _serverAddressController.dispose();
    super.dispose();
  }

  Future<void> _loadPersistedSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final savedAddress = prefs.getString(_serverAddressStorageKey);
      final savedPresets = prefs.getString(_presetStorageKey);

      if (!mounted) {
        return;
      }

      setState(() {
        if (savedAddress != null && savedAddress.trim().isNotEmpty) {
          _serverAddressController.text = savedAddress;
        }

        if (savedPresets != null && savedPresets.isNotEmpty) {
          final decoded = json.decode(savedPresets);
          if (decoded is List) {
            final loaded = decoded
                .whereType<Map>()
                .map(
                  (entry) => BroadcastPreset.fromJson(
                    Map<String, dynamic>.from(entry),
                  ),
                )
                .where((preset) => preset.name.trim().isNotEmpty)
                .toList();

            _presets
              ..clear()
              ..addAll(loaded.isEmpty ? [_defaultPreset] : loaded);
          }
        }
      });
    } catch (e) {
      print('Settings load error: $e');
    }
  }

  Future<void> _savePresets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = json.encode(
        _presets.map((preset) => preset.toJson()).toList(),
      );
      await prefs.setString(_presetStorageKey, encoded);
    } catch (e) {
      print('Preset save error: $e');
    }
  }

  Future<void> _saveServerAddress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _serverAddressStorageKey,
        _serverAddressController.text.trim(),
      );
    } catch (e) {
      print('Server address save error: $e');
    }
  }

  Future<void> _fetchPlatforms() async {
    final serverAddress = _serverAddressController.text.trim();
    _saveServerAddress();
    if (serverAddress.isEmpty) {
      setState(() {
        _statusMessage = 'サーバーアドレスが空です';
        _isConnected = false;
      });
      return;
    }

    try {
      final uri = Uri.parse('$serverAddress/platforms/');
      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              throw TimeoutException('接続タイムアウト');
            },
          );

      if (response.statusCode == 200) {
        try {
          print('Response body: ${response.body}'); // デバッグ用
          final data = json.decode(response.body);
          print('Decoded data type: ${data.runtimeType}'); // デバッグ用
          print('Decoded data: $data'); // デバッグ用

          // レスポンスがエラーメッセージの場合
          if (data is Map &&
              data.containsKey('status') &&
              data['status'] == 'error') {
            setState(() {
              _statusMessage = 'サーバーエラー: ${data['message'] ?? 'Unknown error'}';
              _isConnected = false;
            });
            return;
          }

          // 正常なレスポンスの場合
          if (data is Map) {
            final platformsData = data['platforms'];
            print(
              'Platforms data type: ${platformsData?.runtimeType}',
            ); // デバッグ用

            if (platformsData == null) {
              setState(() {
                _statusMessage = 'エラー: platforms data is null';
                _isConnected = false;
                _platforms = [];
              });
              return;
            }

            if (platformsData is Map) {
              final platforms = <PlatformInfo>[];

              (platformsData).forEach((key, value) {
                try {
                  print(
                    'Processing platform: $key with value: $value',
                  ); // デバッグ用
                  if (value is Map) {
                    final platform = PlatformInfo.fromJson(
                      key.toString(),
                      Map<String, dynamic>.from(value),
                    );
                    platforms.add(platform);
                  }
                } catch (e) {
                  print('Error parsing platform $key: $e');
                }
              });

              // プラットフォームIDでソート
              platforms.sort((a, b) => a.id.compareTo(b.id));

              setState(() {
                _platforms = platforms;
                _statusMessage = '接続成功 (${platforms.length} platforms)';
                _isConnected = true;
              });
            } else {
              setState(() {
                _statusMessage =
                    'エラー: Invalid platforms data format (type: ${platformsData.runtimeType})';
                _isConnected = false;
              });
            }
          } else {
            setState(() {
              _statusMessage =
                  'エラー: Invalid response format (type: ${data.runtimeType})';
              _isConnected = false;
            });
          }
        } catch (e, stackTrace) {
          setState(() {
            _statusMessage = 'データ解析エラー: ${e.toString()}';
            _isConnected = false;
          });
          print('Parse error: $e');
          print('Stack trace: $stackTrace');
          print('Response body: ${response.body}');
        }
      } else {
        setState(() {
          _statusMessage = 'エラー: ${response.statusCode} - ${response.body}';
          _isConnected = false;
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = '接続エラー: ${e.toString()}';
        _isConnected = false;
        _platforms = [];
      });
      print('Fetch platforms error: $e');
    }
  }

  void _startPolling() {
    _pollingTimer?.cancel();
    _fetchPlatforms();
    _pollingTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _fetchPlatforms(),
    );
  }

  void _stopPolling() {
    _pollingTimer?.cancel();
    setState(() {
      _statusMessage = 'ポーリング停止';
      _isConnected = false;
    });
  }

  Future<void> _sendBroadcast({
    required String platformId,
    required Map<String, dynamic> state,
    String component = 'main',
    int priority = 0,
  }) async {
    final serverAddress = _serverAddressController.text.trim();
    _saveServerAddress();
    if (serverAddress.isEmpty) {
      _showMessage('サーバーアドレスが空です');
      return;
    }

    try {
      final requiredVariables = await _detectTemplateVariables(component);
      final missingVariables = _findMissingVariables(state, requiredVariables);
      if (missingVariables.isNotEmpty) {
        _showMessage('不足変数があるため送信できません: ${missingVariables.join(', ')}');
        return;
      }

      final requestBody = {
        'platform_id': int.parse(platformId),
        'state': state,
        'component': component,
        'priority': priority,
      };

      print('Broadcasting to: $serverAddress/broadcast/');
      print('Request body: ${json.encode(requestBody)}');

      final uri = Uri.parse('$serverAddress/broadcast/');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: json.encode(requestBody),
          )
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              throw TimeoutException('接続タイムアウト');
            },
          );

      print('Broadcast response status: ${response.statusCode}');
      print('Broadcast response body: ${response.body}');

      if (response.statusCode == 200) {
        try {
          final data = json.decode(response.body);
          print('Decoded broadcast response: $data');
          print('Response type: ${data.runtimeType}');

          if (data is Map) {
            final status = data['status'];
            if (status == 'success') {
              _showMessage('放送リクエスト送信成功: Platform $platformId');
            } else if (status == 'error') {
              _showMessage('エラー: ${data['message'] ?? 'Unknown error'}');
            } else {
              _showMessage('不明なステータス: $status');
            }
          } else {
            _showMessage('想定外のレスポンス形式: ${data.runtimeType}');
          }
        } catch (e, stackTrace) {
          _showMessage('レスポンス解析エラー: ${e.toString()}');
          print('Parse error: $e');
          print('Stack trace: $stackTrace');
          print('Response body: ${response.body}');
        }
      } else {
        _showMessage('エラー: ${response.statusCode} - ${response.reasonPhrase}');
        print('Error response: ${response.body}');
      }
    } catch (e, stackTrace) {
      _showMessage('送信エラー: ${e.toString()}');
      print('Broadcast error: $e');
      print('Stack trace: $stackTrace');
    }
  }

  void _showMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
    }
  }

  Future<Set<String>> _detectTemplateVariables(String component) async {
    final serverAddress = _serverAddressController.text.trim();
    if (serverAddress.isEmpty) {
      throw const FormatException('サーバーアドレスが空です');
    }

    final safeComponent = component.trim().isEmpty ? 'main' : component.trim();
    final uri = Uri.parse('$serverAddress/templates/');

    final response = await http
        .get(uri)
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            throw TimeoutException('テンプレート取得タイムアウト');
          },
        );

    if (response.statusCode != 200) {
      throw Exception('テンプレート取得失敗: ${response.statusCode}');
    }

    final decoded = json.decode(response.body);
    if (decoded is! Map) {
      throw const FormatException('テンプレート一覧の形式が不正です');
    }

    final templates = Map<String, dynamic>.from(decoded);
    if (!templates.containsKey(safeComponent)) {
      throw FormatException('Template "$safeComponent" が見つかりません');
    }

    final variables = <String>{};
    _collectVariablesLikeServerResolve(
      templates[safeComponent],
      <String, dynamic>{},
      variables,
      templates,
      <String>{},
    );
    variables.removeWhere((variable) => variable.isEmpty);
    return variables;
  }

  dynamic _getByPathLikeServer(
    dynamic source,
    String path, {
    dynamic fallback,
  }) {
    if (path.isEmpty) {
      return source;
    }

    dynamic current = source;
    for (final part in path.split('.')) {
      if (current is Map && current.containsKey(part)) {
        current = current[part];
      } else {
        return fallback;
      }
    }

    return current;
  }

  Map<String, dynamic> _toMapLikeServer(dynamic value) {
    if (value is Map) {
      final result = <String, dynamic>{};
      value.forEach((key, val) {
        result[key.toString()] = _toMapLikeServer(val);
      });
      return result;
    }
    return {'val': value};
  }

  void _collectVariablesLikeServerResolve(
    dynamic node,
    Map<String, dynamic> state,
    Set<String> variables,
    Map<String, dynamic> templates,
    Set<String> visiting,
  ) {
    final variablePattern = RegExp(r'\{([^{}]+)\}');

    if (node is String) {
      for (final match in variablePattern.allMatches(node)) {
        final captured = match.group(1)?.trim();
        if (captured != null && captured.isNotEmpty) {
          variables.add(captured);
        }
      }
      return;
    }

    if (node is List) {
      for (final item in node) {
        _collectVariablesLikeServerResolve(
          item,
          state,
          variables,
          templates,
          visiting,
        );
      }
      return;
    }

    if (node is Map) {
      final functionName = node['function'];
      final paramsRaw = node['params'];
      final params = paramsRaw is Map ? paramsRaw : const <String, dynamic>{};

      if (functionName == 'component') {
        final refId = params['id'];
        if (refId is String && refId.isNotEmpty) {
          // 循環参照を防ぎつつ component 参照先を再帰的に解析
          if (!visiting.contains(refId) && templates.containsKey(refId)) {
            visiting.add(refId);
            _collectVariablesLikeServerResolve(
              templates[refId],
              state,
              variables,
              templates,
              visiting,
            );
            visiting.remove(refId);
          }
        }
        return;
      }

      if (functionName == 'switch') {
        final variablePath = (params['variable'] ?? '').toString();
        final casesRaw = params['cases'];
        final cases = casesRaw is Map ? casesRaw : const <String, dynamic>{};

        var val = _getByPathLikeServer(state, variablePath, fallback: null);

        if (val == null) {
          val = 'default';
        }

        if (val is bool) {
          val = val.toString().toLowerCase();
        } else {
          val = val.toString();
        }

        final target = cases[val] ?? cases['default'] ?? const [];
        _collectVariablesLikeServerResolve(
          target,
          state,
          variables,
          templates,
          visiting,
        );
        return;
      }

      if (functionName == 'loop') {
        final listVar = (params['list_var'] ?? '').toString();
        if (listVar.isNotEmpty) {
          variables.add(listVar);
        }
        final itemTemplate = params['item_template'] ?? const [];
        final listData = _getByPathLikeServer(
          state,
          listVar,
          fallback: const [],
        );

        if (listData is Iterable) {
          final asList = listData.toList();
          for (var i = 0; i < asList.length; i++) {
            final itemData = asList[i];
            final localItem = _toMapLikeServer(itemData);
            localItem['is_first'] = i == 0;
            localItem['is_last'] = i == asList.length - 1;

            final localState = Map<String, dynamic>.from(state);
            localState['item'] = localItem;

            _collectVariablesLikeServerResolve(
              itemTemplate,
              localState,
              variables,
              templates,
              visiting,
            );
          }
        }
        return;
      }

      for (final value in node.values) {
        _collectVariablesLikeServerResolve(
          value,
          state,
          variables,
          templates,
          visiting,
        );
      }
    }
  }

  bool _hasStatePath(Map<String, dynamic> state, String path) {
    final segments = path.split('.');
    dynamic current = state;

    for (final segment in segments) {
      if (current is! Map) {
        return false;
      }
      if (!current.containsKey(segment)) {
        return false;
      }
      current = current[segment];
    }

    return true;
  }

  List<String> _findMissingVariables(
    Map<String, dynamic> state,
    Set<String> requiredVariables,
  ) {
    final missing = <String>[];

    for (final variable in requiredVariables) {
      // loop内の item.* はテンプレート処理時に内部で展開されるため除外
      if (variable.startsWith('item.')) {
        continue;
      }
      if (!_hasStatePath(state, variable)) {
        missing.add(variable);
      }
    }

    missing.sort();
    return missing;
  }

  Future<BroadcastPreset?> _showPresetEditorDialog({BroadcastPreset? preset}) {
    final nameController = TextEditingController(text: preset?.name ?? '');
    final componentController = TextEditingController(
      text: preset?.component ?? 'main',
    );
    final priorityController = TextEditingController(
      text: (preset?.priority ?? 0).toString(),
    );
    final stateController = TextEditingController(
      text:
          preset?.stateJson ??
          '{\n  "platform": "{platform}",\n  "dest": "station_a",\n  "type": "local"\n}',
    );

    return showDialog<BroadcastPreset>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(preset == null ? 'プリセット追加' : 'プリセット編集'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '名前',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: componentController,
                decoration: const InputDecoration(
                  labelText: 'Component',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: priorityController,
                decoration: const InputDecoration(
                  labelText: 'Priority',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: stateController,
                decoration: const InputDecoration(
                  labelText: 'State JSON',
                  border: OutlineInputBorder(),
                  helperText: '{platform} は現在のplatform_idに置換されます',
                ),
                maxLines: 6,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () {
              try {
                final name = nameController.text.trim();
                final component = componentController.text.trim();
                final priority = int.parse(priorityController.text.trim());
                final stateText = stateController.text.trim();

                if (name.isEmpty) {
                  throw const FormatException('名前を入力してください');
                }
                if (component.isEmpty) {
                  throw const FormatException('Componentを入力してください');
                }

                final previewJson = stateText.replaceAll('{platform}', '0');
                final decoded = json.decode(previewJson);
                if (decoded is! Map) {
                  throw const FormatException('State JSONはオブジェクト形式で入力してください');
                }

                Navigator.pop(
                  context,
                  BroadcastPreset(
                    name: name,
                    component: component,
                    priority: priority,
                    stateJson: stateText,
                  ),
                );
              } catch (e) {
                _showMessage('プリセット保存エラー: ${e.toString()}');
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showPresetSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('プリセット設定 (paramsのみ)'),
          content: SizedBox(
            width: 520,
            child: _presets.isEmpty
                ? const Text('プリセットがありません')
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: _presets.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final preset = _presets[index];
                      return ListTile(
                        title: Text(preset.name),
                        subtitle: Text(
                          'component=${preset.component}, priority=${preset.priority}',
                        ),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit),
                              tooltip: '編集',
                              onPressed: () async {
                                final edited = await _showPresetEditorDialog(
                                  preset: preset,
                                );
                                if (edited != null) {
                                  setState(() {
                                    _presets[index] = edited;
                                  });
                                  await _savePresets();
                                  setDialogState(() {});
                                }
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete),
                              tooltip: '削除',
                              onPressed: () {
                                setState(() {
                                  _presets.removeAt(index);
                                  if (_presets.isEmpty) {
                                    _presets.add(_defaultPreset);
                                  }
                                });
                                _savePresets();
                                setDialogState(() {});
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                final created = await _showPresetEditorDialog();
                if (created != null) {
                  setState(() {
                    _presets.add(created);
                  });
                  await _savePresets();
                  setDialogState(() {});
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('追加'),
            ),
          ],
        ),
      ),
    );
  }

  void _showBroadcastDialog(String platformId) {
    final TextEditingController componentController = TextEditingController(
      text: 'main',
    );
    final TextEditingController priorityController = TextEditingController(
      text: '0',
    );
    final TextEditingController stateController = TextEditingController(
      text:
          '{\n  "platform": "$platformId",\n  "dest": "station_a",\n  "type": "local"\n}',
    );
    final detectedVariables = <String>{};
    var missingVariables = <String>[];
    var isDetecting = false;
    BroadcastPreset? selectedPreset;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<List<String>> detectMissingVariables({
            required Map<String, dynamic> state,
            required String component,
            bool notify = true,
          }) async {
            setDialogState(() {
              isDetecting = true;
            });

            try {
              final variables = await _detectTemplateVariables(component);
              final missing = _findMissingVariables(state, variables);

              setDialogState(() {
                detectedVariables
                  ..clear()
                  ..addAll(variables);
                missingVariables = missing;
              });

              if (notify) {
                if (variables.isEmpty) {
                  _showMessage('波括弧変数は見つかりませんでした');
                } else if (missing.isEmpty) {
                  _showMessage('必要変数はすべてstateに含まれています');
                } else {
                  _showMessage('不足変数: ${missing.join(', ')}');
                }
              }

              return missing;
            } finally {
              if (mounted) {
                setDialogState(() {
                  isDetecting = false;
                });
              }
            }
          }

          return AlertDialog(
            title: Text('放送リクエスト - Platform $platformId'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'リクエスト形式:',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const Text(
                    '{"platform_id": 0, "state": {...}, "component": "main", "priority": 0}',
                    style: TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int>(
                    value: null,
                    decoration: const InputDecoration(
                      labelText: 'プリセット適用',
                      border: OutlineInputBorder(),
                      helperText: 'プリセットは params のみ適用されます',
                    ),
                    items: _presets.asMap().entries.map((entry) {
                      return DropdownMenuItem<int>(
                        value: entry.key,
                        child: Text(entry.value.name),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      final preset = _presets[value];
                      selectedPreset = preset;

                      componentController.text = preset.component;
                      priorityController.text = preset.priority.toString();
                      stateController.text = preset.stateJson.replaceAll(
                        '{platform}',
                        platformId,
                      );
                      setDialogState(() {
                        detectedVariables.clear();
                        missingVariables = [];
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  if (selectedPreset != null)
                    Text(
                      '適用中プリセット: ${selectedPreset!.name}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                  if (selectedPreset != null) const SizedBox(height: 12),
                  TextField(
                    controller: componentController,
                    decoration: const InputDecoration(
                      labelText: 'Component (テンプレートID)',
                      border: OutlineInputBorder(),
                      helperText: 'デフォルト: main',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: priorityController,
                    decoration: const InputDecoration(
                      labelText: 'Priority (優先度)',
                      border: OutlineInputBorder(),
                      helperText: '0が最高優先度',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: stateController,
                    decoration: const InputDecoration(
                      labelText: 'State (JSON Object)',
                      border: OutlineInputBorder(),
                      helperText: 'テンプレート展開用の状態データ',
                    ),
                    maxLines: 6,
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: isDetecting
                          ? null
                          : () async {
                              try {
                                final decoded = json.decode(
                                  stateController.text,
                                );
                                if (decoded is! Map) {
                                  throw const FormatException(
                                    'State must be a JSON object',
                                  );
                                }

                                final state = Map<String, dynamic>.from(
                                  decoded,
                                );
                                final component =
                                    componentController.text.trim().isEmpty
                                    ? 'main'
                                    : componentController.text.trim();

                                await detectMissingVariables(
                                  state: state,
                                  component: component,
                                );
                              } catch (e) {
                                _showMessage('変数検知エラー: ${e.toString()}');
                              }
                            },
                      icon: const Icon(Icons.search),
                      label: Text(isDetecting ? '検知中...' : '必要変数を検知'),
                    ),
                  ),
                  if (detectedVariables.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '検出変数: ${detectedVariables.join(', ')}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                  if (missingVariables.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '不足変数: ${missingVariables.join(', ')}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.orangeAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('キャンセル'),
              ),
              ElevatedButton(
                onPressed: isDetecting
                    ? null
                    : () async {
                        try {
                          final decoded = json.decode(stateController.text);
                          if (decoded is! Map) {
                            throw const FormatException(
                              'State must be a JSON object',
                            );
                          }

                          final state = Map<String, dynamic>.from(decoded);
                          final priority = int.parse(priorityController.text);
                          final component =
                              componentController.text.trim().isEmpty
                              ? 'main'
                              : componentController.text.trim();

                          final missing = await detectMissingVariables(
                            state: state,
                            component: component,
                            notify: false,
                          );

                          if (missing.isNotEmpty) {
                            _showMessage(
                              '不足変数があるため送信できません: ${missing.join(', ')}',
                            );
                            return;
                          }

                          if (!context.mounted) {
                            return;
                          }

                          Navigator.pop(context);
                          _sendBroadcast(
                            platformId: platformId,
                            state: state,
                            component: component,
                            priority: priority,
                          );
                        } catch (e, stackTrace) {
                          print('Dialog input error: $e');
                          print('Stack trace: $stackTrace');
                          _showMessage('入力エラー: ${e.toString()}');
                        }
                      },
                child: const Text('送信'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('Train Station Player Helper'),
        actions: [
          SizedBox(
            width: 300,
            child: TextField(
              controller: _serverAddressController,
              onSubmitted: (_) {
                _saveServerAddress();
              },
              decoration: const InputDecoration(
                hintText: 'Server Address',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
                filled: true,
                fillColor: Colors.white12,
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              _pollingTimer?.isActive == true ? Icons.stop : Icons.play_arrow,
            ),
            onPressed: _pollingTimer?.isActive == true
                ? _stopPolling
                : _startPolling,
            tooltip: _pollingTimer?.isActive == true ? 'ポーリング停止' : 'ポーリング開始',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchPlatforms,
            tooltip: '手動更新',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showPresetSettingsDialog,
            tooltip: 'プリセット設定',
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8.0),
            color: _isConnected ? Colors.green[700] : Colors.red[700],
            child: Row(
              children: [
                Icon(
                  _isConnected ? Icons.check_circle : Icons.error,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusMessage,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _platforms.isEmpty
                ? const Center(
                    child: Text(
                      'プラットフォーム情報がありません',
                      style: TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8.0),
                    itemCount: _platforms.length,
                    itemBuilder: (context, index) {
                      final platform = _platforms[index];
                      return PlatformCard(
                        platform: platform,
                        onBroadcast: () => _showBroadcastDialog(platform.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class PlatformCard extends StatelessWidget {
  final PlatformInfo platform;
  final VoidCallback onBroadcast;

  const PlatformCard({
    super.key,
    required this.platform,
    required this.onBroadcast,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = platform.isPlaying
        ? Colors.green
        : platform.queueSize > 0
        ? Colors.orange
        : Colors.grey;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4.0),
      color: Colors.grey[850],
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Platform ${platform.id}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: statusColor, width: 1),
                  ),
                  child: Text(
                    platform.isPlaying ? '再生中' : 'アイドル',
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _InfoItem(
                    label: '優先度',
                    value: platform.currentPriority == -1
                        ? '未使用'
                        : platform.currentPriority.toString(),
                    icon: Icons.priority_high,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _InfoItem(
                    label: 'キューサイズ',
                    value: platform.queueSize.toString(),
                    icon: Icons.queue_music,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onBroadcast,
                icon: const Icon(Icons.broadcast_on_home),
                label: const Text('放送リクエスト'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue[700],
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoItem extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _InfoItem({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[800],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.blue[300]),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 12, color: Colors.grey[400]),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
