import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'api_exception.dart';

typedef UnauthorizedCallback = Future<void> Function();
typedef UploadProgressCallback = void Function(double progress);

class ApiClient {
  ApiClient({
    required this.tokenProvider,
    required this.onUnauthorized,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  final String? Function() tokenProvider;
  final UnauthorizedCallback onUnauthorized;
  final http.Client _httpClient;

  Future<Map<String, dynamic>> getJson(
    String endpoint, {
    Map<String, Object?>? query,
  }) => _request('GET', endpoint, query: query);

  Future<Uint8List> downloadBytes(
    String endpoint, {
    Map<String, Object?>? query,
  }) async {
    final request = http.Request('GET', AppConfig.apiUri(endpoint, query));
    request.headers['Accept'] = '*/*';
    _attachAuthorization(request.headers);

    try {
      final streamed = await _httpClient
          .send(request)
          .timeout(AppConfig.requestTimeout);
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response.bodyBytes;
      }
      _decodeResponse(response);
    } on TimeoutException {
      throw const ApiException('La conexión excedió el tiempo de espera.');
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException('No se pudo conectar con el servidor.');
    }
    throw const ApiException('No se pudo descargar el archivo.');
  }

  Future<Map<String, dynamic>> postJson(
    String endpoint, {
    Map<String, dynamic>? body,
    bool authenticated = true,
  }) => _request('POST', endpoint, body: body, authenticated: authenticated);

  Future<Map<String, dynamic>> deleteJson(
    String endpoint, {
    Map<String, dynamic>? body,
  }) => _request('DELETE', endpoint, body: body);

  Future<Map<String, dynamic>> _request(
    String method,
    String endpoint, {
    Map<String, Object?>? query,
    Map<String, dynamic>? body,
    bool authenticated = true,
  }) async {
    final request = http.Request(method, AppConfig.apiUri(endpoint, query));
    request.headers['Accept'] = 'application/json';
    if (authenticated) _attachAuthorization(request.headers);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }

    try {
      final streamed = await _httpClient
          .send(request)
          .timeout(AppConfig.requestTimeout);
      final response = await http.Response.fromStream(streamed);
      return _decodeResponse(response, authenticated: authenticated);
    } on TimeoutException {
      throw const ApiException('La conexión excedió el tiempo de espera.');
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException('No se pudo conectar con el servidor.');
    }
  }

  Future<Map<String, dynamic>> uploadDocument({
    required int carpetaId,
    required int tipoDocumentoId,
    required String idempotencyKey,
    required String filePath,
    required String fileName,
    required UploadProgressCallback onProgress,
    String? personalizedDescription,
  }) async {
    try {
      final request = _ProgressMultipartRequest(
        'POST',
        AppConfig.apiUri('carpeta-obras/$carpetaId/documentos'),
        onProgress,
      );
      _attachAuthorization(request.headers);
      request.headers['Accept'] = 'application/json';
      request.fields['tipoDocumentoId'] = tipoDocumentoId.toString();
      request.fields['idempotencyKey'] = idempotencyKey;
      final description = personalizedDescription?.trim();
      if (description != null && description.isNotEmpty) {
        request.fields['descripcionPersonalizada'] = description;
      }
      request.files.add(
        await http.MultipartFile.fromPath(
          'archivo',
          filePath,
          filename: fileName,
        ),
      );

      final streamed = await _httpClient
          .send(request)
          .timeout(AppConfig.uploadTimeout);
      final response = await http.Response.fromStream(streamed);
      return _decodeResponse(response);
    } on FileSystemException {
      throw const ApiException(
        'El archivo temporal ya no está disponible. Seleccionalo nuevamente.',
        code: 'local_file_unavailable',
      );
    } on TimeoutException {
      throw const ApiException('La carga excedió el tiempo de espera.');
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException(
        'No se pudo cargar el archivo. Verificá tu conexión.',
      );
    }
  }

  void _attachAuthorization(Map<String, String> headers) {
    final token = tokenProvider();
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
  }

  Map<String, dynamic> _decodeResponse(
    http.Response response, {
    bool authenticated = true,
  }) {
    dynamic payload;
    if (response.bodyBytes.isNotEmpty) {
      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      try {
        payload = jsonDecode(text);
      } catch (_) {
        payload = {'error': text};
      }
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload is Map<String, dynamic> ? payload : <String, dynamic>{};
    }

    if (response.statusCode == 401 && authenticated) {
      unawaited(onUnauthorized());
    }
    final map = payload is Map<String, dynamic>
        ? payload
        : const <String, dynamic>{};
    final rawDetails = map['details'];
    final details = rawDetails is List
        ? rawDetails
              .map((value) => value is Map ? value['message'] ?? value : value)
              .map((value) => value.toString())
              .toList()
        : const <String>[];
    throw ApiException(
      map['error']?.toString() ??
          'El servidor devolvió un error (${response.statusCode}).',
      statusCode: response.statusCode,
      details: details,
    );
  }

  void close() => _httpClient.close();
}

class _ProgressMultipartRequest extends http.MultipartRequest {
  _ProgressMultipartRequest(super.method, super.url, this.onProgress);

  final UploadProgressCallback onProgress;

  @override
  http.ByteStream finalize() {
    final total = contentLength;
    var sent = 0;
    onProgress(0);
    final source = super.finalize();
    final stream = source.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          sent += chunk.length;
          if (total > 0) onProgress((sent / total).clamp(0, 1));
          sink.add(chunk);
        },
      ),
    );
    return http.ByteStream(stream);
  }
}
