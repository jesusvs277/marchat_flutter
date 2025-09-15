// pubspec.yaml dependencies needed:
// flutter:
//   sdk: flutter
// web_socket_channel: ^2.4.0
// shared_preferences: ^2.2.2
// file_picker: ^6.1.1
// path_provider: ^2.1.1
// crypto: ^3.0.3
// http: ^1.1.0
// flutter_secure_storage: ^9.0.0
// audioplayers: ^5.2.1

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// Constants
const int maxMessages = 100;
const int maxUsersDisplay = 20;
const Duration pingPeriod = Duration(seconds: 50);
const Duration reconnectMaxDelay = Duration(seconds: 30);
const double userListMinWidth = 180;
const double inputMinHeight = 80;
const double defaultWindowWidth = 1000;
const double defaultWindowHeight = 700;

// Enums
enum MessageType {
  text,
  file,
  system,
}

enum ThemeType {
  light,
  dark,
  system,
}

// Data Models
class Config {
  String username;
  String serverURL;
  ThemeType theme;
  bool twentyFourHour;

  Config({
    required this.username,
    required this.serverURL,
    this.theme = ThemeType.system,
    this.twentyFourHour = true,
  });

  Map<String, dynamic> toJson() => {
        'username': username,
        'serverURL': serverURL,
        'theme': theme.toString(),
        'twentyFourHour': twentyFourHour,
      };

  factory Config.fromJson(Map<String, dynamic> json) => Config(
        username: json['username'] ?? '',
        serverURL: json['serverURL'] ?? '',
        theme: ThemeType.values.firstWhere(
          (e) => e.toString() == json['theme'],
          orElse: () => ThemeType.system,
        ),
        twentyFourHour: json['twentyFourHour'] ?? true,
      );
}

class Message {
  String sender;
  String content;
  DateTime createdAt;
  MessageType type;
  FileMeta? file;

  Message({
    required this.sender,
    required this.content,
    required this.createdAt,
    this.type = MessageType.text,
    this.file,
  });

  Map<String, dynamic> toJson() => {
        'sender': sender,
        'content': content,
        'created_at': createdAt.toIso8601String(),
        'type': type.index,
        if (file != null) 'file': file!.toJson(),
      };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        sender: json['sender'] ?? '',
        content: json['content'] ?? '',
        createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
        type: MessageType.values[json['type'] ?? 0],
        file: json['file'] != null ? FileMeta.fromJson(json['file']) : null,
      );
}

class FileMeta {
  String filename;
  int size;
  Uint8List data;

  FileMeta({
    required this.filename,
    required this.size,
    required this.data,
  });

  Map<String, dynamic> toJson() => {
        'filename': filename,
        'size': size,
        'data': base64Encode(data),
      };

  factory FileMeta.fromJson(Map<String, dynamic> json) => FileMeta(
        filename: json['filename'] ?? '',
        size: json['size'] ?? 0,
        data: base64Decode(json['data'] ?? ''),
      );
}

class Handshake {
  String username;
  bool admin;
  String adminKey;

  Handshake({
    required this.username,
    this.admin = false,
    this.adminKey = '',
  });

  Map<String, dynamic> toJson() => {
        'username': username,
        'admin': admin,
        'admin_key': adminKey,
      };
}

// Crypto/Keystore placeholder (simplified version)
class KeyStore {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  Map<String, SessionKey> _sessionKeys = {};
  String? _globalE2EKey;

  Future<void> initialize(String passphrase) async {
    // Load global E2E key from environment or secure storage
    _globalE2EKey = Platform.environment['MARCHAT_GLOBAL_E2E_KEY'] ??
        await _storage.read(key: 'global_e2e_key');

    if (_globalE2EKey != null) {
      _sessionKeys['global'] = SessionKey(
        keyID: 'global',
        key: base64Decode(_globalE2EKey!),
      );
    }
  }

  SessionKey? getSessionKey(String conversationID) {
    return _sessionKeys[conversationID];
  }

  Future<EncryptedMessage> encryptMessage(
      String sender, String content, String conversationID) async {
    final sessionKey = getSessionKey(conversationID);
    if (sessionKey == null) {
      throw Exception('No session key for conversation: $conversationID');
    }

    // Simplified encryption (in real implementation, use proper AES-GCM)
    final nonce = List<int>.generate(12, (i) => Random().nextInt(256));
    final contentBytes = utf8.encode(content);
    final encrypted = _xorEncrypt(contentBytes, sessionKey.key);

    return EncryptedMessage(
      sender: sender,
      createdAt: DateTime.now(),
      encrypted: Uint8List.fromList(encrypted),
      nonce: Uint8List.fromList(nonce),
      isEncrypted: true,
      type: MessageType.text,
    );
  }

  Future<Message> decryptMessage(
      EncryptedMessage encMsg, String conversationID) async {
    final sessionKey = getSessionKey(conversationID);
    if (sessionKey == null) {
      throw Exception('No session key for conversation: $conversationID');
    }

    // Simplified decryption
    final decrypted = _xorEncrypt(encMsg.encrypted, sessionKey.key);
    final content = utf8.decode(decrypted);

    return Message(
      sender: encMsg.sender,
      content: content,
      createdAt: encMsg.createdAt,
      type: encMsg.type,
    );
  }

  List<int> _xorEncrypt(List<int> data, List<int> key) {
    final result = <int>[];
    for (int i = 0; i < data.length; i++) {
      result.add(data[i] ^ key[i % key.length]);
    }
    return result;
  }
}

class SessionKey {
  String keyID;
  List<int> key;

  SessionKey({required this.keyID, required this.key});
}

class EncryptedMessage {
  String sender;
  DateTime createdAt;
  Uint8List encrypted;
  Uint8List nonce;
  bool isEncrypted;
  MessageType type;

  EncryptedMessage({
    required this.sender,
    required this.createdAt,
    required this.encrypted,
    required this.nonce,
    required this.isEncrypted,
    required this.type,
  });
}

// Main Application
class MarchatApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'marchat',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: ThemeMode.system,
      home: ConfigScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// Configuration Screen
class ConfigScreen extends StatefulWidget {
  @override
  _ConfigScreenState createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _serverController = TextEditingController(text: 'ws://localhost:8080/ws');
  final _adminKeyController = TextEditingController();
  final _e2ePassController = TextEditingController();
  final _globalE2EKeyController = TextEditingController();

  bool _isAdmin = false;
  bool _enableE2E = false;
  ThemeType _selectedTheme = ThemeType.system;

  @override
  void dispose() {
    _usernameController.dispose();
    _serverController.dispose();
    _adminKeyController.dispose();
    _e2ePassController.dispose();
    _globalE2EKeyController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) return;

    final config = Config(
      username: _usernameController.text,
      serverURL: _serverController.text,
      theme: _selectedTheme,
      twentyFourHour: true,
    );

    KeyStore? keystore;
    if (_enableE2E) {
      keystore = KeyStore();
      if (_globalE2EKeyController.text.isNotEmpty) {
        await const FlutterSecureStorage()
            .write(key: 'global_e2e_key', value: _globalE2EKeyController.text);
      }
      await keystore.initialize(_e2ePassController.text);
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          config: config,
          keystore: keystore,
          isAdmin: _isAdmin,
          adminKey: _adminKeyController.text,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('marchat - Configuration'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            controller: _usernameController,
                            decoration: const InputDecoration(
                              labelText: 'Username',
                              hintText: 'Enter your username',
                            ),
                            validator: (value) =>
                                value?.isEmpty == true ? 'Username is required' : null,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _serverController,
                            decoration: const InputDecoration(
                              labelText: 'Server URL',
                            ),
                            validator: (value) =>
                                value?.isEmpty == true ? 'Server URL is required' : null,
                          ),
                          const SizedBox(height: 16),
                          CheckboxListTile(
                            title: const Text('Connect as admin'),
                            value: _isAdmin,
                            onChanged: (value) => setState(() => _isAdmin = value ?? false),
                          ),
                          if (_isAdmin) ...[
                            TextFormField(
                              controller: _adminKeyController,
                              decoration: const InputDecoration(
                                labelText: 'Admin Key',
                                hintText: 'Admin key (if admin)',
                              ),
                              obscureText: true,
                            ),
                            const SizedBox(height: 16),
                          ],
                          CheckboxListTile(
                            title: const Text('Enable end-to-end encryption'),
                            value: _enableE2E,
                            onChanged: (value) => setState(() => _enableE2E = value ?? false),
                          ),
                          if (_enableE2E) ...[
                            TextFormField(
                              controller: _e2ePassController,
                              decoration: const InputDecoration(
                                labelText: 'E2E Passphrase',
                                hintText: 'Keystore passphrase (if E2E)',
                              ),
                              obscureText: true,
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _globalE2EKeyController,
                              decoration: const InputDecoration(
                                labelText: 'Global E2E Key',
                                hintText: 'Global E2E key (MARCHAT_GLOBAL_E2E_KEY)',
                              ),
                              obscureText: true,
                            ),
                            const SizedBox(height: 16),
                          ],
                          DropdownButtonFormField<ThemeType>(
                            decoration: const InputDecoration(labelText: 'Theme'),
                            value: _selectedTheme,
                            items: ThemeType.values
                                .map((theme) => DropdownMenuItem(
                                      value: theme,
                                      child: Text(theme.toString().split('.').last),
                                    ))
                                .toList(),
                            onChanged: (value) =>
                                setState(() => _selectedTheme = value ?? ThemeType.system),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    onPressed: () => SystemNavigator.pop(),
                    child: const Text('Cancel'),
                  ),
                  ElevatedButton(
                    onPressed: _connect,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).primaryColor,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Connect'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Main Chat Screen
class ChatScreen extends StatefulWidget {
  final Config config;
  final KeyStore? keystore;
  final bool isAdmin;
  final String adminKey;

  const ChatScreen({
    Key? key,
    required this.config,
    this.keystore,
    this.isAdmin = false,
    this.adminKey = '',
  }) : super(key: key);

  @override
  _ChatScreenState createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  // Connection
  WebSocketChannel? _channel;
  bool _connected = false;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  Duration _reconnectDelay = const Duration(seconds: 1);

  // UI Controllers
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();

  // Data
  List<Message> _messages = [];
  List<String> _users = [];
  Map<String, FileMeta> _receivedFiles = {};

  // State
  String _status = 'Connecting...';
  bool _sending = false;
  bool _twentyFourHour = true;
  int _selectedUserIndex = -1;
  String _selectedUser = '';

  // Bell notifications
  bool _bellEnabled = true;
  bool _bellOnMention = false;
  DateTime _lastBellTime = DateTime.now();
  final Duration _minBellInterval = const Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    _twentyFourHour = widget.config.twentyFourHour;
    _connect();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _channel?.sink.close();
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }

  // Connection Management
  Future<void> _connect() async {
    try {
      setState(() {
        _status = 'Connecting...';
        _connected = false;
      });

      final uri = Uri.parse(widget.config.serverURL)
          .replace(queryParameters: {'username': widget.config.username});

      _channel = WebSocketChannel.connect(uri);
      
      // Send handshake
      final handshake = Handshake(
        username: widget.config.username,
        admin: widget.isAdmin,
        adminKey: widget.adminKey,
      );
      
      _channel!.sink.add(jsonEncode(handshake.toJson()));

      // Listen to messages
      _channel!.stream.listen(
        _handleMessage,
        onError: _handleConnectionError,
        onDone: () => _handleConnectionError('Connection closed'),
      );

      setState(() {
        _connected = true;
        _status = '✅ Connected to server!';
        _reconnectDelay = const Duration(seconds: 1);
      });

      _startPingTimer();
    } catch (e) {
      _handleConnectionError(e.toString());
    }
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(pingPeriod, (timer) {
      if (_connected && _channel != null) {
        _channel!.sink.add('ping');
      }
    });
  }

  void _handleMessage(dynamic message) async {
    try {
      final data = jsonDecode(message);
      
      if (data is Map<String, dynamic>) {
        if (data.containsKey('type') && data.containsKey('data')) {
          _handleSpecialMessage(data);
        } else if (data.containsKey('sender')) {
          await _handleChatMessage(Message.fromJson(data));
        }
      }
    } catch (e) {
      debugPrint('Failed to parse message: $e');
    }
  }

  void _handleSpecialMessage(Map<String, dynamic> data) {
    final type = data['type'];
    final payload = data['data'];

    switch (type) {
      case 'userlist':
        if (payload is Map<String, dynamic> && payload.containsKey('users')) {
          setState(() {
            _users = List<String>.from(payload['users']);
          });
        }
        break;
      case 'auth_failed':
        if (payload is Map<String, dynamic> && payload.containsKey('reason')) {
          _showErrorDialog('Authentication Failed', payload['reason']);
        }
        break;
    }
  }

  Future<void> _handleChatMessage(Message message) async {
    // Decrypt if encrypted and keystore available
    if (widget.keystore != null && message.content.isNotEmpty) {
      try {
        final decoded = base64Decode(message.content);
        if (decoded.length > 12) {
          final nonce = decoded.sublist(0, 12);
          final encrypted = decoded.sublist(12);
          
          final encryptedMsg = EncryptedMessage(
            sender: message.sender,
            createdAt: message.createdAt,
            encrypted: Uint8List.fromList(encrypted),
            nonce: Uint8List.fromList(nonce),
            isEncrypted: true,
            type: message.type,
          );

          final globalKey = widget.keystore!.getSessionKey('global');
          if (globalKey != null) {
            message = await widget.keystore!.decryptMessage(encryptedMsg, 'global');
          } else {
            message.content = '[ENCRYPTED - NO GLOBAL KEY]';
          }
        }
      } catch (e) {
        // Not encrypted or decryption failed
      }
    }

    // Check for bell notification
    if (_shouldPlayBell(message)) {
      _playBell();
    }

    setState(() {
      _messages.add(message);
      if (_messages.length > maxMessages) {
        _messages.removeAt(0);
      }
      
      if (message.type == MessageType.file && message.file != null) {
        _receivedFiles[message.file!.filename] = message.file!;
      }
      
      _sending = false;
    });

    // Auto-scroll to bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _handleConnectionError(dynamic error) {
    setState(() {
      _connected = false;
      _status = '🚫 Connection lost. Reconnecting...';
    });

    _channel?.sink.close();
    _pingTimer?.cancel();

    if (error.toString().contains('Username already taken')) {
      setState(() {
        _status = '❌ Username already taken - please restart with a different username';
      });
      return;
    }

    // Exponential backoff reconnection
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, () {
      _connect();
    });

    if (_reconnectDelay < reconnectMaxDelay) {
      _reconnectDelay = Duration(
        milliseconds: (_reconnectDelay.inMilliseconds * 2)
            .clamp(1000, reconnectMaxDelay.inMilliseconds),
      );
    }
  }

  // Message Sending
  void _sendMessage([String? text]) async {
    final content = text ?? _messageController.text.trim();
    if (content.isEmpty) return;

    // Handle commands
    if (_handleCommand(content)) {
      _messageController.clear();
      return;
    }

    if (!_connected || _channel == null) {
      setState(() => _status = '❌ Not connected');
      return;
    }

    setState(() => _sending = true);

    try {
      if (widget.keystore != null) {
        await _sendEncryptedMessage(content);
      } else {
        await _sendPlainMessage(content);
      }
    } catch (e) {
      setState(() {
        _status = '❌ Failed to send message: $e';
        _sending = false;
      });
    }

    _messageController.clear();
  }

  Future<void> _sendPlainMessage(String content) async {
    final message = Message(
      sender: widget.config.username,
      content: content,
      createdAt: DateTime.now(),
    );

    _channel!.sink.add(jsonEncode(message.toJson()));
    setState(() => _sending = false);
  }

  Future<void> _sendEncryptedMessage(String content) async {
    final globalKey = widget.keystore!.getSessionKey('global');
    if (globalKey == null) {
      throw Exception('No global key available for encryption');
    }

    final encryptedMsg = await widget.keystore!
        .encryptMessage(widget.config.username, content, 'global');

    final combinedData = [...encryptedMsg.nonce, ...encryptedMsg.encrypted];
    final finalContent = base64Encode(combinedData);

    final message = Message(
      sender: widget.config.username,
      content: finalContent,
      createdAt: DateTime.now(),
    );

    _channel!.sink.add(jsonEncode(message.toJson()));
    setState(() => _sending = false);
  }

  // Command Handling
  bool _handleCommand(String text) {
    switch (text) {
      case ':clear':
        _clearChat();
        return true;
      case ':time':
        _toggleTimeFormat();
        return true;
      case ':bell':
        _toggleBell();
        return true;
      case ':bell-mention':
        _toggleBellOnMention();
        return true;
      case ':code':
        _showCodeSnippetDialog();
        return true;
      case ':sendfile':
        _showFilePickerDialog();
        return true;
      default:
        if (text.startsWith(':sendfile ')) {
          final filePath = text.substring(10).trim();
          _sendFile(filePath);
          return true;
        }
        if (text.startsWith(':savefile ')) {
          final filename = text.substring(10).trim();
          _saveFile(filename);
          return true;
        }
        if (text.startsWith(':theme ')) {
          final theme = text.substring(7).trim();
          _setTheme(theme);
          return true;
        }
        if (widget.isAdmin && _isAdminCommand(text)) {
          _sendAdminCommand(text);
          return true;
        }
    }
    return false;
  }

  bool _isAdminCommand(String text) {
    const adminCommands = [
      ':cleardb', ':backup', ':stats', ':kick', ':ban', 
      ':unban', ':allow', ':forcedisconnect'
    ];
    return adminCommands.any((cmd) => text == cmd || text.startsWith('$cmd '));
  }

  void _sendAdminCommand(String command) {
    if (!widget.isAdmin) {
      setState(() => _status = '❌ Admin privileges required');
      return;
    }

    final message = Message(
      sender: widget.config.username,
      content: command,
      createdAt: DateTime.now(),
    );

    _channel!.sink.add(jsonEncode(message.toJson()));
    setState(() => _status = '✅ Admin command sent');
  }

  // Bell Notifications
  bool _shouldPlayBell(Message message) {
    if (message.sender == widget.config.username || !_bellEnabled) {
      return false;
    }

    if (_bellOnMention) {
      final mentionPattern = '@${widget.config.username}';
      return message.content.toLowerCase().contains(mentionPattern.toLowerCase());
    }

    return true;
  }

  void _playBell() {
    final now = DateTime.now();
    if (now.difference(_lastBellTime) < _minBellInterval) return;
    _lastBellTime = now;

    // Play system sound (simplified)
    SystemSound.play(SystemSoundType.alert);
  }

  // UI Actions
  void _clearChat() {
    setState(() {
      _messages.clear();
      _status = 'Chat cleared';
    });
  }

  void _toggleTimeFormat() {
    setState(() {
      _twentyFourHour = !_twentyFourHour;
      widget.config.twentyFourHour = _twentyFourHour;
      _status = 'Time format: ${_twentyFourHour ? "24h" : "12h"}';
    });
  }

  void _toggleBell() {
    setState(() {
      _bellEnabled = !_bellEnabled;
      _status = 'Bell notifications ${_bellEnabled ? "enabled" : "disabled"}';
    });
    if (_bellEnabled) _playBell();
  }

  void _toggleBellOnMention() {
    setState(() {
      _bellOnMention = !_bellOnMention;
      _status = 'Bell on mention only ${_bellOnMention ? "enabled" : "disabled"}';
    });
    if (_bellOnMention && _bellEnabled) _playBell();
  }

  void _setTheme(String themeName) {
    ThemeType theme;
    switch (themeName.toLowerCase()) {
      case 'light':
        theme = ThemeType.light;
        break;
      case 'dark':
        theme = ThemeType.dark;
        break;
      default:
        theme = ThemeType.system;
    }
    
    setState(() {
      widget.config.theme = theme;
      _status = 'Theme changed to $themeName';
    });
  }

  // File Operations
  Future<void> _sendFile(String? filePath) async {
    if (!_connected || _channel == null) {
      setState(() => _status = '❌ Not connected');
      return;
    }

    try {
      Uint8List? fileBytes;
      String filename;

      if (filePath != null) {
        final file = File(filePath);
        fileBytes = await file.readAsBytes();
        filename = file.path.split('/').last;
      } else {
        final result = await FilePicker.platform.pickFiles();
        if (result == null || result.files.isEmpty) return;
        
        final pickedFile = result.files.first;
        fileBytes = pickedFile.bytes ?? await File(pickedFile.path!).readAsBytes();
        filename = pickedFile.name;
      }

      // Check file size limit
      const maxBytes = 1024 * 1024; // 1MB default
      if (fileBytes.length > maxBytes) {
        setState(() => _status = '❌ File too large (max 1MB)');
        return;
      }

      final message = Message(
        sender: widget.config.username,
        type: MessageType.file,
        content: '',
        createdAt: DateTime.now(),
        file: FileMeta(
          filename: filename,
          size: fileBytes.length,
          data: fileBytes,
        ),
      );

      _channel!.sink.add(jsonEncode(message.toJson()));
      setState(() => _status = '✅ File sent: $filename');
    } catch (e) {
      setState(() => _status = '❌ Failed to send file: $e');
    }
  }

  Future<void> _saveFile(String filename) async {
    final file = _receivedFiles[filename];
    if (file == null) {
      setState(() => _status = '❌ File not found: $filename');
      return;
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      final filePath = '${directory.path}/$filename';
      final savedFile = File(filePath);
      await savedFile.writeAsBytes(file.data);
      setState(() => _status = '✅ File saved: $filePath');
    } catch (e) {
      setState(() => _status = '❌ Failed to save file: $e');
    }
  }

  // Dialog Methods
  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showHelpDialog() {
    final helpText = _generateHelpText();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('marchat Help'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: SingleChildScrollView(
            child: SelectableText(helpText),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _generateHelpText() {
    String help = '''# marchat Help

## Keyboard Shortcuts
- **Enter**: Send message
- **Shift+Enter**: New line in message

## Menu Commands
### File Menu
- **Send File**: Send a file to the chat
- **Save Received File**: Save a file that was sent to you

### Edit Menu  
- **Clear Chat**: Clear the chat history
- **Code Snippet**: Create a syntax highlighted code snippet

### View Menu
- **Toggle Time Format**: Switch between 12h and 24h time display
- **Themes**: Change between Light, Dark, and System themes

### Audio Menu
- **Toggle Bell**: Enable/disable notification sounds
- **Toggle Bell on Mention Only**: Only play sound when mentioned

## Chat Commands
- `:clear` - Clear chat history
- `:time` - Toggle 12/24h time format  
- `:bell` - Toggle notification bell
- `:bell-mention` - Toggle bell only on mentions
- `:code` - Create code snippet
- `:sendfile [path]` - Send a file
- `:savefile <filename>` - Save received file
- `:theme <name>` - Change theme (light, dark, system)
''';

    if (widget.isAdmin) {
      help += '''
### Admin Menu (Admin Only)
- **Database Operations**: Access database management
- **User Actions**: Kick, ban, or disconnect users
- **Unban/Allow User**: Restore user access

## Admin Commands  
- `:cleardb` - Clear database
- `:backup` - Backup database
- `:stats` - Show database stats
- `:kick <user>` - Kick user
- `:ban <user>` - Ban user  
- `:unban <user>` - Unban user
- `:allow <user>` - Allow user (override kick)
- `:forcedisconnect <user>` - Force disconnect user
''';
    }

    return help;
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About marchat'),
        content: const SelectableText('''# marchat Flutter Client

**Version**: 1.0.0  
**Build**: Flutter Edition

A secure, real-time chat client with end-to-end encryption support.

## Features
- Real-time messaging
- File sharing
- End-to-end encryption
- Multiple themes
- Admin capabilities
- Cross-platform support

Built with Flutter and Dart.'''),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showCodeSnippetDialog() {
    final languageController = TextEditingController();
    final codeController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Code Snippet'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: Column(
            children: [
              TextField(
                controller: languageController,
                decoration: const InputDecoration(
                  labelText: 'Language',
                  hintText: 'e.g., dart, python, javascript',
                ),
              ),
              const SizedBox(height: 16),
              const Text('Code:'),
              const SizedBox(height: 8),
              Expanded(
                child: TextField(
                  controller: codeController,
                  decoration: const InputDecoration(
                    hintText: 'Enter your code here...',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: null,
                  expands: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (codeController.text.isNotEmpty) {
                final language = languageController.text;
                final code = codeController.text;
                final formattedCode = '```$language\n$code\n```';
                _sendMessage(formattedCode);
              }
              Navigator.pop(context);
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  void _showFilePickerDialog() {
    _sendFile(null); // null triggers FilePicker
  }

  void _showSaveFileDialog() {
    if (_receivedFiles.isEmpty) {
      _showErrorDialog('No Files', 'No files have been received yet.');
      return;
    }

    final fileNames = _receivedFiles.keys.toList()..sort();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save Received Files'),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: ListView.builder(
            itemCount: fileNames.length,
            itemBuilder: (context, index) {
              final filename = fileNames[index];
              return ListTile(
                title: Text(filename),
                onTap: () {
                  Navigator.pop(context);
                  _saveFile(filename);
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showAdminDialog() {
    if (!widget.isAdmin) {
      setState(() => _status = '❌ Admin privileges required');
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Admin - Database Operations'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _confirmAdminAction(
                  'Clear Database',
                  'This will delete all messages. Continue?',
                  ':cleardb',
                );
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Clear Database'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _sendAdminCommand(':backup');
                setState(() => _status = '✅ Database backup initiated');
              },
              child: const Text('Backup Database'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _sendAdminCommand(':stats');
                setState(() => _status = '✅ Database stats requested');
              },
              child: const Text('Show Statistics'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _confirmAdminAction(String title, String message, String command) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _sendAdminCommand(command);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  void _executeAdminAction(String action) {
    if (!widget.isAdmin) {
      setState(() => _status = '❌ Admin privileges required');
      return;
    }

    if (_selectedUser.isEmpty) {
      setState(() => _status = '❌ No user selected');
      return;
    }

    if (_selectedUser == widget.config.username) {
      setState(() => _status = '❌ Cannot perform action on yourself');
      return;
    }

    final command = ':$action $_selectedUser';
    _sendAdminCommand(command);

    // Clear selection after kick/ban/disconnect
    if (action == 'kick' || action == 'ban' || action == 'forcedisconnect') {
      setState(() {
        _selectedUserIndex = -1;
        _selectedUser = '';
      });
    }
  }

  void _promptAdminAction(String action) {
    if (!widget.isAdmin) {
      setState(() => _status = '❌ Admin privileges required');
      return;
    }

    final usernameController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${action[0].toUpperCase()}${action.substring(1)} User'),
        content: TextField(
          controller: usernameController,
          decoration: InputDecoration(
            labelText: 'Username',
            hintText: 'Enter username to $action...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (usernameController.text.isNotEmpty) {
                final command = ':$action ${usernameController.text}';
                _sendAdminCommand(command);
              }
              Navigator.pop(context);
            },
            child: const Text('Execute'),
          ),
        ],
      ),
    );
  }

  // Message Processing
  String _processMessageContent(String content, String sender) {
    // Convert basic emojis
    final emojis = {
      ':)': '😊',
      ':(': '🙁',
      ':D': '😃',
      '<3': '❤️',
      ':P': '😛',
    };

    String processed = content;
    emojis.forEach((key, value) {
      processed = processed.replaceAll(key, value);
    });

    // Process code blocks (simplified)
    final codeBlockRegex = RegExp(r'```([a-zA-Z0-9+]*)\n([\s\S]*?)```');
    processed = processed.replaceAllMapped(codeBlockRegex, (match) {
      return '```\n${match.group(2)}\n```';
    });

    // Highlight mentions (simplified)
    final mentionRegex = RegExp(r'\B@([a-zA-Z0-9_]+)\b');
    final mentions = mentionRegex.allMatches(processed);
    for (final match in mentions) {
      final username = match.group(1);
      if (_users.any((user) => user.toLowerCase() == username?.toLowerCase())) {
        processed = processed.replaceAll(match.group(0)!, '**${match.group(0)!}**');
      }
    }

    return processed;
  }

  Widget _buildMessageWidget(Message message) {
    final isMe = message.sender == widget.config.username;
    final timeFormat = _twentyFourHour ? 'HH:mm:ss' : 'hh:mm:ss a';
    
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      color: isMe ? Theme.of(context).primaryColor.withOpacity(0.1) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  isMe ? '${message.sender} (me)' : message.sender,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const Spacer(),
                Text(
                  _formatTime(message.createdAt),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (message.type == MessageType.file && message.file != null)
              Text(
                '📎 File: ${message.file!.filename} (${message.file!.size} bytes)\n\nUse File → Save Received File to save',
                style: const TextStyle(fontStyle: FontStyle.italic),
              )
            else
              SelectableText(
                _processMessageContent(message.content, message.sender),
                style: const TextStyle(fontSize: 14),
              ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    if (_twentyFourHour) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
    } else {
      final hour = time.hour == 0 ? 12 : (time.hour > 12 ? time.hour - 12 : time.hour);
      final amPm = time.hour < 12 ? 'AM' : 'PM';
      return '${hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')} $amPm';
    }
  }

  // Build UI
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('marchat - ${widget.config.username}'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          PopupMenuButton<String>(
            onSelected: _handleMenuAction,
            itemBuilder: (context) => [
              // File Menu
              const PopupMenuItem(value: 'send_file', child: Text('Send File')),
              const PopupMenuItem(value: 'save_file', child: Text('Save Received File')),
              const PopupMenuDivider(),
              
              // Edit Menu
              const PopupMenuItem(value: 'clear_chat', child: Text('Clear Chat')),
              const PopupMenuItem(value: 'code_snippet', child: Text('Code Snippet')),
              const PopupMenuDivider(),
              
              // View Menu
              const PopupMenuItem(value: 'toggle_time', child: Text('Toggle Time Format')),
              const PopupMenuItem(value: 'theme_light', child: Text('Light Theme')),
              const PopupMenuItem(value: 'theme_dark', child: Text('Dark Theme')),
              const PopupMenuItem(value: 'theme_system', child: Text('System Theme')),
              const PopupMenuDivider(),
              
              // Audio Menu
              const PopupMenuItem(value: 'toggle_bell', child: Text('Toggle Bell')),
              const PopupMenuItem(value: 'toggle_bell_mention', child: Text('Toggle Bell on Mention')),
              
              // Admin Menu (if admin)
              if (widget.isAdmin) ...[
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'admin_db', child: Text('Database Operations')),
                const PopupMenuItem(value: 'admin_kick', child: Text('Kick Selected User')),
                const PopupMenuItem(value: 'admin_ban', child: Text('Ban Selected User')),
                const PopupMenuItem(value: 'admin_disconnect', child: Text('Force Disconnect User')),
                const PopupMenuItem(value: 'admin_unban', child: Text('Unban User')),
                const PopupMenuItem(value: 'admin_allow', child: Text('Allow User')),
              ],
              
              const PopupMenuDivider(),
              // Help Menu
              const PopupMenuItem(value: 'help', child: Text('Show Help')),
              const PopupMenuItem(value: 'about', child: Text('About')),
            ],
          ),
        ],
      ),
      body: Row(
        children: [
          // User List
          Container(
            width: userListMinWidth,
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor.withOpacity(0.1),
                  ),
                  child: Text(
                    'Users (${_users.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _users.length,
                    itemBuilder: (context, index) {
                      final user = _users[index];
                      final isMe = user == widget.config.username;
                      final isSelected = widget.isAdmin && _selectedUserIndex == index;
                      
                      return ListTile(
                        leading: Icon(
                          isSelected ? Icons.arrow_right : Icons.circle,
                          size: isSelected ? 20 : 8,
                          color: isMe 
                              ? Theme.of(context).primaryColor
                              : (isSelected ? Colors.red : Colors.grey),
                        ),
                        title: Text(
                          isMe ? '$user (me)' : user,
                          style: TextStyle(
                            fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? Colors.red : null,
                          ),
                        ),
                        selected: isSelected,
                        onTap: widget.isAdmin && !isMe ? () {
                          setState(() {
                            if (_selectedUserIndex == index) {
                              _selectedUserIndex = -1;
                              _selectedUser = '';
                            } else {
                              _selectedUserIndex = index;
                              _selectedUser = user;
                            }
                          });
                        } : null,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          
          // Chat Area
          Expanded(
            child: Column(
              children: [
                // Status Bar
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    border: Border(
                      bottom: BorderSide(color: Theme.of(context).dividerColor),
                    ),
                  ),
                  child: Text(
                    _status,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                
                // Messages
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      return _buildMessageWidget(_messages[index]);
                    },
                  ),
                ),
                
                // Message Input
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: Theme.of(context).dividerColor),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _messageController,
                          focusNode: _focusNode,
                          decoration: const InputDecoration(
                            hintText: 'Type your message...',
                            border: OutlineInputBorder(),
                          ),
                          maxLines: 3,
                          minLines: 1,
                          onSubmitted: _sendMessage,
                          onChanged: (text) {
                            // Handle Shift+Enter for new line (managed by TextField)
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _sending ? null : () => _sendMessage(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).primaryColor,
                          foregroundColor: Colors.white,
                        ),
                        child: Text(_sending ? 'Sending...' : 'Send'),
                      ),
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

  void _handleMenuAction(String action) {
    switch (action) {
      case 'send_file':
        _showFilePickerDialog();
        break;
      case 'save_file':
        _showSaveFileDialog();
        break;
      case 'clear_chat':
        _clearChat();
        break;
      case 'code_snippet':
        _showCodeSnippetDialog();
        break;
      case 'toggle_time':
        _toggleTimeFormat();
        break;
      case 'theme_light':
        _setTheme('light');
        break;
      case 'theme_dark':
        _setTheme('dark');
        break;
      case 'theme_system':
        _setTheme('system');
        break;
      case 'toggle_bell':
        _toggleBell();
        break;
      case 'toggle_bell_mention':
        _toggleBellOnMention();
        break;
      case 'admin_db':
        _showAdminDialog();
        break;
      case 'admin_kick':
        _executeAdminAction('kick');
        break;
      case 'admin_ban':
        _executeAdminAction('ban');
        break;
      case 'admin_disconnect':
        _executeAdminAction('forcedisconnect');
        break;
      case 'admin_unban':
        _promptAdminAction('unban');
        break;
      case 'admin_allow':
        _promptAdminAction('allow');
        break;
      case 'help':
        _showHelpDialog();
        break;
      case 'about':
        _showAboutDialog();
        break;
    }
  }
}

// Entry Point
void main() {
  runApp(MarchatApp());
}