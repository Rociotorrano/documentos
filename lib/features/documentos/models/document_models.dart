class DocumentFolder {
  const DocumentFolder({
    required this.id,
    required this.year,
    required this.procedure,
    required this.address,
    required this.locality,
    required this.municipalAccount,
  });

  final int id;
  final int year;
  final String procedure;
  final String address;
  final String locality;
  final String municipalAccount;

  factory DocumentFolder.fromJson(Map<String, dynamic> json) => DocumentFolder(
    id: _int(json['id']),
    year: _int(json['anio']),
    procedure: json['tramite']?.toString() ?? '',
    address: json['direccion']?.toString() ?? '',
    locality: json['localidad']?.toString() ?? '',
    municipalAccount: json['cuentaMunicipal']?.toString() ?? '',
  );
}

class DocumentRecord {
  const DocumentRecord({
    required this.id,
    required this.typeId,
    required this.version,
    required this.isCurrent,
    required this.status,
    required this.originalName,
    required this.extension,
    required this.originalSize,
    required this.finalSize,
    required this.createdAt,
    required this.downloadable,
    this.personalizedDescription,
    this.availableAt,
    this.deletedAt,
    this.deleteAfter,
  });

  final int id;
  final int typeId;
  final int version;
  final bool isCurrent;
  final String status;
  final String originalName;
  final String extension;
  final int originalSize;
  final int finalSize;
  final DateTime createdAt;
  final DateTime? availableAt;
  final DateTime? deletedAt;
  final DateTime? deleteAfter;
  final bool downloadable;
  final String? personalizedDescription;

  int get savedPercent => originalSize > finalSize && originalSize > 0
      ? ((1 - finalSize / originalSize) * 100).round()
      : 0;

  factory DocumentRecord.fromJson(Map<String, dynamic> json) => DocumentRecord(
    id: _int(json['id']),
    typeId: _int(json['tipoDocumentoId']),
    version: _int(json['version']),
    isCurrent: json['esActual'] == true,
    status: json['estado']?.toString() ?? '',
    originalName: json['nombreOriginal']?.toString() ?? 'Documento',
    extension: json['extension']?.toString() ?? '',
    originalSize: _int(json['tamanoOriginal']),
    finalSize: _int(json['tamanoFinal']),
    createdAt:
        _date(json['fechaCreacion']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    availableAt: _date(json['fechaDisponible']),
    deletedAt: _date(json['fechaEliminacion']),
    deleteAfter: _date(json['eliminarDespues']),
    downloadable: json['descargable'] == true,
    personalizedDescription:
        json['descripcionPersonalizada']?.toString() ??
        json['descripcion_personalizada']?.toString(),
  );
}

class DocumentType {
  const DocumentType({
    required this.id,
    required this.slug,
    required this.name,
    required this.description,
    required this.active,
    required this.isRequired,
    required this.order,
    required this.history,
    required this.allowsMultipleCurrent,
    required this.requiresPersonalizedDescription,
    this.current,
    this.currentDocuments = const [],
  });

  final int id;
  final String slug;
  final String name;
  final String description;
  final bool active;
  final bool isRequired;
  final int order;
  final DocumentRecord? current;
  final List<DocumentRecord> history;
  final bool allowsMultipleCurrent;
  final bool requiresPersonalizedDescription;
  final List<DocumentRecord> currentDocuments;

  bool get hasCurrent => current != null || currentDocuments.isNotEmpty;

  factory DocumentType.fromJson(Map<String, dynamic> json) {
    final id = _int(json['id']);
    final slug = json['slug']?.toString() ?? '';
    final current = json['vigente'];
    final vigentes = json['vigentes'];
    final allowsMultipleCurrent =
        json['multiplesVigentes'] == true ||
        json['multiples_vigentes'] == true ||
        (id == 5 && slug == 'otros');
    final requiresPersonalizedDescription =
        json['requiereDescripcionPersonalizada'] == true ||
        json['requiere_descripcion_personalizada'] == true ||
        (id == 5 && slug == 'otros');
    final currentDocument = current is Map
        ? DocumentRecord.fromJson(Map<String, dynamic>.from(current))
        : null;
    final parsedVigentes = vigentes is List
        ? vigentes
              .whereType<Map>()
              .map(
                (item) =>
                    DocumentRecord.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList()
        : currentDocument == null
        ? const <DocumentRecord>[]
        : [currentDocument];
    final currentDocuments = allowsMultipleCurrent
        ? parsedVigentes
        : currentDocument == null
        ? const <DocumentRecord>[]
        : [currentDocument];
    final history = json['historial'];
    return DocumentType(
      id: id,
      slug: slug,
      name: json['nombre']?.toString() ?? '',
      description: json['descripcion']?.toString() ?? '',
      active: json['activo'] == true,
      isRequired: json['obligatorio'] != false,
      order: _int(json['orden']),
      current: allowsMultipleCurrent ? null : currentDocument,
      currentDocuments: currentDocuments,
      allowsMultipleCurrent: allowsMultipleCurrent,
      requiresPersonalizedDescription: requiresPersonalizedDescription,
      history: history is List
          ? history
                .whereType<Map>()
                .map(
                  (item) =>
                      DocumentRecord.fromJson(Map<String, dynamic>.from(item)),
                )
                .toList()
          : const [],
    );
  }
}

class DocumentsPayload {
  const DocumentsPayload({
    required this.folder,
    required this.types,
    required this.maxFileSize,
    required this.retentionDays,
  });

  final DocumentFolder folder;
  final List<DocumentType> types;
  final int maxFileSize;
  final int retentionDays;

  factory DocumentsPayload.fromJson(Map<String, dynamic> json) {
    final folder = json['carpeta'];
    final types = json['tipos'];
    final config = json['configuracion'];
    final configMap = config is Map ? config : const <String, dynamic>{};
    return DocumentsPayload(
      folder: DocumentFolder.fromJson(
        folder is Map ? Map<String, dynamic>.from(folder) : const {},
      ),
      types: types is List
          ? types
                .whereType<Map>()
                .map(
                  (type) =>
                      DocumentType.fromJson(Map<String, dynamic>.from(type)),
                )
                .toList()
          : const [],
      maxFileSize: _int(
        configMap['tamanoMaximoBytes'],
        fallback: 20 * 1024 * 1024,
      ),
      retentionDays: _int(configMap['retencionDias'], fallback: 30),
    );
  }
}

int _int(Object? value, {int fallback = 0}) =>
    int.tryParse(value?.toString() ?? '') ?? fallback;
DateTime? _date(Object? value) =>
    value == null ? null : DateTime.tryParse(value.toString())?.toLocal();
