import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../storage/secure_token_storage.dart';
import 'auth_user.dart';

enum AuthStatus { initializing, unauthenticated, authenticated }

class AuthController extends ChangeNotifier {
  AuthController([this._storage = const SecureTokenStorage()]) {
    api = ApiClient(
      tokenProvider: () => _token,
      onUnauthorized: _expireSession,
    );
  }

  final SecureTokenStorage _storage;
  late final ApiClient api;
  String? _token;
  AuthUser? _user;
  Set<String> _permissions = <String>{};
  AuthStatus _status = AuthStatus.initializing;
  bool _busy = false;
  String? _errorMessage;

  AuthStatus get status => _status;
  AuthUser? get user => _user;
  bool get busy => _busy;
  String? get errorMessage => _errorMessage;
  Set<String> get permissions => Set.unmodifiable(_permissions);

  bool hasPermission(String code) =>
      _user?.isSuperAdmin == true || _permissions.contains(code);
  bool get canViewDocuments =>
      hasPermission('carpeta_obras_documentos_ver') ||
      hasPermission('carpeta_obras_documentos_gestionar');
  bool get canManageDocuments =>
      hasPermission('carpeta_obras_documentos_gestionar');

  Future<void> initialize() async {
    _status = AuthStatus.initializing;
    _errorMessage = null;
    notifyListeners();

    try {
      final storedToken = await _storage.read();
      if (storedToken == null ||
          storedToken.isEmpty ||
          _isExpired(storedToken)) {
        await _clearSession();
        _status = AuthStatus.unauthenticated;
        return;
      }

      _token = storedToken;
      _user = _userFromToken(storedToken);
      try {
        final profile = await api.getJson('auth/profile');
        _user = AuthUser.fromJson(profile);
        await _loadPermissions();
        _status = AuthStatus.authenticated;
      } on ApiException catch (error) {
        if (error.isUnauthorized) {
          await _clearSession();
          _status = AuthStatus.unauthenticated;
        } else {
          await _clearSession();
          _status = AuthStatus.unauthenticated;
          _errorMessage =
              'No se pudo validar la sesión ni los permisos. Intentá nuevamente.';
        }
      }
    } catch (_) {
      _clearMemorySession();
      await _clearStoredTokenBestEffort();
      _status = AuthStatus.unauthenticated;
      _errorMessage =
          'No se pudo acceder al almacenamiento seguro del dispositivo. '
          'Desbloquealo e intentá nuevamente.';
    } finally {
      notifyListeners();
    }
  }

  Future<bool> login(String username, String password) async {
    if (_busy) return false;
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final response = await api.postJson(
        'auth/login',
        authenticated: false,
        body: {'usuario': username.trim(), 'password': password},
      );
      final token = response['token']?.toString();
      final userJson = response['user'];
      if (token == null || token.isEmpty || userJson is! Map) {
        throw const ApiException(
          'La respuesta de inicio de sesión no es válida.',
        );
      }
      _token = token;
      _user = AuthUser.fromJson(Map<String, dynamic>.from(userJson));
      await _storage.write(token);
      await _loadPermissions();
      _status = AuthStatus.authenticated;
      return true;
    } on ApiException catch (error) {
      await _clearSession();
      _status = AuthStatus.unauthenticated;
      _errorMessage = error.message;
      return false;
    } catch (_) {
      _clearMemorySession();
      await _clearStoredTokenBestEffort();
      _status = AuthStatus.unauthenticated;
      _errorMessage =
          'No se pudo guardar la sesión de forma segura. Intentá nuevamente.';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _loadPermissions() async {
    for (var attempt = 0; attempt < 3; attempt += 1) {
      try {
        final response = await api.getJson('roles/my-permissions');
        final codes = response['permisosCodigos'];
        _permissions = codes is List
            ? codes.map((value) => value.toString()).toSet()
            : <String>{};
        return;
      } on ApiException catch (error) {
        if (error.isUnauthorized || attempt == 2) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
  }

  Future<bool> logout() async {
    if (_busy) return false;
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      try {
        if (_token != null) await api.postJson('auth/logout');
      } catch (_) {
        // La limpieza local no depende de la disponibilidad del servidor.
      }

      try {
        await _storage.clear();
      } catch (_) {
        _status = AuthStatus.authenticated;
        _errorMessage =
            'No se pudo cerrar la sesión porque el almacenamiento seguro no respondió.';
        return false;
      }

      _clearMemorySession();
      _status = AuthStatus.unauthenticated;
      return true;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _expireSession() async {
    if (_status == AuthStatus.unauthenticated) return;
    await _clearSession();
    _status = AuthStatus.unauthenticated;
    _errorMessage = 'Tu sesión venció. Ingresá nuevamente.';
    notifyListeners();
  }

  void _clearMemorySession() {
    _token = null;
    _user = null;
    _permissions = <String>{};
  }

  Future<void> _clearStoredTokenBestEffort() async {
    try {
      await _storage.clear();
    } catch (_) {
      // El estado en memoria se limpia aunque falle el proveedor seguro.
    }
  }

  Future<bool> _clearSession() async {
    _clearMemorySession();
    try {
      await _storage.clear();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _isExpired(String token) {
    final payload = _decodeToken(token);
    final expiration = payload?['exp'];
    final seconds = int.tryParse(expiration?.toString() ?? '');
    if (seconds == null) return false;
    return DateTime.now().millisecondsSinceEpoch >= (seconds * 1000) - 30000;
  }

  AuthUser? _userFromToken(String token) {
    final payload = _decodeToken(token);
    if (payload == null) return null;
    return AuthUser.fromJson({
      'id': payload['id'],
      'usuario': payload['usuario'],
      'rol': payload['rol'],
      'superadmin': payload['superadmin'],
    });
  }

  Map<String, dynamic>? _decodeToken(String token) {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final value = jsonDecode(decoded);
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    api.close();
    super.dispose();
  }
}
