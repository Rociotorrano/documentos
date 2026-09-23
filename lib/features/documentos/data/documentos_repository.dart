import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

import '../../../core/api/api_client.dart';
import '../models/document_models.dart';

class DocumentosRepository {
  const DocumentosRepository(this._api);

  final ApiClient _api;

  Future<DocumentsPayload> getForFolder(int folderId) async {
    final response = await _api.getJson('carpeta-obras/$folderId/documentos');
    return DocumentsPayload.fromJson(response);
  }

  Future<Uint8List> downloadDocument({
    required int folderId,
    required int documentId,
  }) async {
    return _api.downloadBytes(
      'carpeta-obras/$folderId/documentos/$documentId/archivo',
    );
  }

  Future<DocumentRecord> upload({
    required int folderId,
    required int typeId,
    required String idempotencyKey,
    required XFile file,
    required UploadProgressCallback onProgress,
    String? personalizedDescription,
  }) async {
    final response = await _api.uploadDocument(
      carpetaId: folderId,
      tipoDocumentoId: typeId,
      idempotencyKey: idempotencyKey,
      filePath: file.path,
      fileName: file.name,
      onProgress: onProgress,
      personalizedDescription: personalizedDescription,
    );
    return DocumentRecord.fromJson(response);
  }
}
