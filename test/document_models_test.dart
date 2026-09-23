import 'package:flutter_test/flutter_test.dart';
import 'package:gis_documentos/features/documentos/models/document_models.dart';

void main() {
  test('parsea múltiples documentos vigentes de Otros', () {
    final payload = DocumentsPayload.fromJson({
      'carpeta': <String, dynamic>{},
      'tipos': [
        {
          'id': 5,
          'slug': 'otros',
          'nombre': 'Otros',
          'descripcion': 'Documentación adicional',
          'activo': true,
          'obligatorio': false,
          'orden': 5,
          'multiplesVigentes': true,
          'vigentes': [
            {
              'id': 10,
              'tipoDocumentoId': 5,
              'version': 1,
              'esActual': true,
              'estado': 'disponible',
              'nombreOriginal': 'avance.jpg',
              'extension': 'jpg',
              'tamanoOriginal': 100,
              'tamanoFinal': 80,
              'fechaCreacion': '2026-08-10T10:00:00Z',
              'descripcionPersonalizada': 'Fotos del avance',
              'descargable': true,
            },
            {
              'id': 11,
              'tipoDocumentoId': 5,
              'version': 2,
              'esActual': true,
              'estado': 'disponible',
              'nombreOriginal': 'plano.pdf',
              'extension': 'pdf',
              'tamanoOriginal': 200,
              'tamanoFinal': 200,
              'fechaCreacion': '2026-08-10T11:00:00Z',
              'descripcion_personalizada': 'Plano complementario',
              'descargable': true,
            },
          ],
          'historial': [],
        },
      ],
      'configuracion': <String, dynamic>{},
    });

    final type = payload.types.single;

    expect(type.allowsMultipleCurrent, isTrue);
    expect(type.requiresPersonalizedDescription, isTrue);
    expect(type.current, isNull);
    expect(type.hasCurrent, isTrue);
    expect(type.currentDocuments, hasLength(2));
    expect(
      type.currentDocuments.first.personalizedDescription,
      'Fotos del avance',
    );
    expect(
      type.currentDocuments.last.personalizedDescription,
      'Plano complementario',
    );
  });

  test('parsea múltiples archivos de un tipo normal sin descripción extra', () {
    final type = DocumentType.fromJson({
      'id': 1,
      'slug': 'caratula',
      'nombre': 'Carátula',
      'descripcion': 'Documento principal',
      'activo': true,
      'obligatorio': true,
      'orden': 1,
      'multiplesVigentes': true,
      'requiereDescripcionPersonalizada': false,
      'vigentes': [
        {
          'id': 20,
          'tipoDocumentoId': 1,
          'version': 3,
          'esActual': true,
          'estado': 'disponible',
          'nombreOriginal': 'caratula.pdf',
          'extension': 'pdf',
          'tamanoOriginal': 300,
          'tamanoFinal': 300,
          'fechaCreacion': '2026-08-10T12:00:00Z',
          'descargable': true,
        },
      ],
      'historial': [],
    });

    expect(type.allowsMultipleCurrent, isTrue);
    expect(type.requiresPersonalizedDescription, isFalse);
    expect(type.hasCurrent, isTrue);
    expect(type.currentDocuments, hasLength(1));
    expect(type.current, isNull);
  });
}
