import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PendingImageSelection {
  const PendingImageSelection({required this.folderId, required this.typeId});

  final int folderId;
  final int typeId;
}

class PendingPickerStorage {
  const PendingPickerStorage();

  static const _folderKey = 'gis_pending_picker_folder_id';
  static const _typeKey = 'gis_pending_picker_type_id';
  static const _storage = FlutterSecureStorage();

  Future<void> write({required int folderId, required int typeId}) async {
    await _storage.write(key: _folderKey, value: folderId.toString());
    await _storage.write(key: _typeKey, value: typeId.toString());
  }

  Future<PendingImageSelection?> read() async {
    final values = await Future.wait([
      _storage.read(key: _folderKey),
      _storage.read(key: _typeKey),
    ]);
    final folderId = int.tryParse(values[0] ?? '');
    final typeId = int.tryParse(values[1] ?? '');
    if (folderId == null || typeId == null) return null;
    return PendingImageSelection(folderId: folderId, typeId: typeId);
  }

  Future<void> clear() async {
    await _storage.delete(key: _folderKey);
    await _storage.delete(key: _typeKey);
  }
}
