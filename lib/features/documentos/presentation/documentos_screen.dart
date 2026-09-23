import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:doc_scan_lite/doc_scan_lite.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';

import '../../../core/api/api_exception.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/storage/pending_picker_storage.dart';
import '../data/documentos_repository.dart';
import '../models/document_models.dart';

class DocumentosScreen extends StatefulWidget {
  const DocumentosScreen({
    super.key,
    required this.authController,
    required this.folderId,
    required this.fallbackTitle,
  });

  final AuthController authController;
  final int folderId;
  final String fallbackTitle;

  @override
  State<DocumentosScreen> createState() => _DocumentosScreenState();
}

enum _FileSource { camera, gallery, files }

class _DocScannerScreen extends StatefulWidget {
  const _DocScannerScreen();

  @override
  State<_DocScannerScreen> createState() => _DocScannerScreenState();
}

class _DocScannerScreenState extends State<_DocScannerScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  CameraDescription? _camera;
  late final DocScanController _scan = DocScanController();
  late final Future<void> _initFuture;
  bool _capturing = false;
  bool _reopening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initFuture = _init();
  }

  Future<void> _init() async {
    _camera = await _pickCamera();
    await _scan.start();
    await _openCamera(_camera!);
  }

  Future<CameraDescription> _pickCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw CameraException('no_camera', 'Sin cámara disponible.');
    }
    return cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
  }

  Future<void> _openCamera(CameraDescription description) async {
    final controller = CameraController(
      description,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await controller.initialize();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    _cameraController = controller;
    if (!controller.value.isStreamingImages) {
      await controller.startImageStream(_scan.processFrame);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      final controller = _cameraController;
      if (controller == null) return;
      _cameraController = null;
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      final camera = _camera;
      if (camera == null || _cameraController != null || _reopening) return;
      _reopening = true;
      _openCamera(camera).whenComplete(() => _reopening = false);
    }
  }

  Future<void> _capture() async {
    if (_capturing) return;
    final frame = _scan.latestFrame;
    if (frame == null) {
      _showHint('Esperá un momento, estoy iniciando la cámara…');
      return;
    }
    setState(() => _capturing = true);
    _scan.pause();
    final controller = _cameraController;
    if (controller == null) {
      _scan.resume();
      setState(() => _capturing = false);
      return;
    }

    try {
      final qT = _quarterTurnsFor(controller.value.deviceOrientation);
      final photo = await controller.takePicture();
      final bytes = await File(photo.path).readAsBytes();
      try {
        await File(photo.path).delete();
      } catch (_) {}

      if (!mounted) {
        _scan.resume();
        return;
      }

      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        _scan.resume();
        setState(() => _capturing = false);
        _showHint('No se pudo generar la imagen, probá de nuevo.');
        return;
      }

      // Foto en orientación de pantalla (vertical, si el teléfono está vertical).
      final full = img.bakeOrientation(decoded);
      final latest = _scan.latestFrame;
      final frameQuad = latest?.quad;

      final DocQuad seed;
      if (latest != null && frameQuad != null) {
        seed = _mapQuadToDisplay(
          frameQuad,
          latest.width,
          latest.height,
          qT,
          full.width.toDouble(),
          full.height.toDouble(),
        );
      } else {
        final mw = full.width * 0.08;
        final mh = full.height * 0.08;
        seed = DocQuad(
          tl: DocCorner(mw, mh),
          tr: DocCorner(full.width - mw, mh),
          br: DocCorner(full.width - mw, full.height - mh),
          bl: DocCorner(mw, full.height - mh),
        );
      }

      // Vista previa reducida para ajustar a mano.
      const maxEditWidth = 1600;
      final edit = full.width > maxEditWidth
          ? img.copyResize(full, width: maxEditWidth)
          : full;
      final uiImage = await _toUiImage(edit);
      if (!mounted) {
        uiImage.dispose();
        _scan.resume();
        return;
      }

      final scaleX = full.width / edit.width;
      final scaleY = full.height / edit.height;
      final editSeed = DocQuad(
        tl: DocCorner(seed.tl.x / scaleX, seed.tl.y / scaleY),
        tr: DocCorner(seed.tr.x / scaleX, seed.tr.y / scaleY),
        br: DocCorner(seed.br.x / scaleX, seed.br.y / scaleY),
        bl: DocCorner(seed.bl.x / scaleX, seed.bl.y / scaleY),
      );

      final adjusted = await Navigator.of(context).push<DocQuad>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _AdjustScreen(
            image: uiImage,
            frameWidth: edit.width.toDouble(),
            frameHeight: edit.height.toDouble(),
            initialQuad: editSeed,
          ),
        ),
      );

      if (!mounted) {
        _scan.resume();
        return;
      }
      if (adjusted == null) {
        _scan.resume();
        setState(() => _capturing = false);
        return;
      }

      final finalQuad = DocQuad(
        tl: DocCorner(adjusted.tl.x * scaleX, adjusted.tl.y * scaleY),
        tr: DocCorner(adjusted.tr.x * scaleX, adjusted.tr.y * scaleY),
        br: DocCorner(adjusted.br.x * scaleX, adjusted.br.y * scaleY),
        bl: DocCorner(adjusted.bl.x * scaleX, adjusted.bl.y * scaleY),
      );

      final outWidth =
          finalQuad.tl.distanceTo(finalQuad.tr).round().clamp(64, 2600).toInt();
      final outHeight = finalQuad.tl
          .distanceTo(finalQuad.bl)
          .round()
          .clamp(64, 2600)
          .toInt();

      final rectified = img.copyRectify(
        full,
        topLeft: img.Point(finalQuad.tl.x, finalQuad.tl.y),
        topRight: img.Point(finalQuad.tr.x, finalQuad.tr.y),
        bottomLeft: img.Point(finalQuad.bl.x, finalQuad.bl.y),
        bottomRight: img.Point(finalQuad.br.x, finalQuad.br.y),
        toImage: img.Image(width: outWidth, height: outHeight),
        interpolation: img.Interpolation.linear,
      );

      _scan.resume();
      if (!mounted) return;
      setState(() => _capturing = false);

      final name =
          'scan_${DateFormat('yyyyMMdd_HHmmss', 'es_AR').format(DateTime.now())}.png';
      Navigator.of(context).pop(
        _ScannedImage(bytes: Uint8List.fromList(img.encodePng(rectified)), name: name),
      );
    } on CameraException {
      _scan.resume();
      if (!mounted) return;
      setState(() => _capturing = false);
      _showHint('No se pudo tomar la foto, probá de nuevo.');
    } catch (_) {
      _scan.resume();
      if (!mounted) return;
      setState(() => _capturing = false);
      _showHint('No se pudo generar la imagen, probá de nuevo.');
    }
  }

  void _showHint(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _scan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No se pudo iniciar la cámara: ${snapshot.error}',
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final controller = _cameraController;
          if (controller == null || !controller.value.isInitialized) {
            return const Center(child: CircularProgressIndicator());
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              _DocPreview(
                controller: controller,
                scan: _scan,
              ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: IconButton.filledTonal(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                      tooltip: 'Cerrar',
                    ),
                  ),
                ),
              ),
              AnimatedBuilder(
                animation: _scan,
                builder: (context, child) {
                  return _ScanControls(
                    isLocked: _scan.isLocked,
                    isCapturing: _capturing,
                    onCapture: _capture,
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ScannedImage {
  const _ScannedImage({required this.bytes, required this.name});

  final Uint8List bytes;
  final String name;
}

int _quarterTurnsFor(DeviceOrientation orientation) {
  switch (orientation) {
    case DeviceOrientation.landscapeRight:
      return 1;
    case DeviceOrientation.portraitDown:
      return 2;
    case DeviceOrientation.landscapeLeft:
      return 3;
    case DeviceOrientation.portraitUp:
      return 0;
  }
}

DocQuad _mapQuadToDisplay(
  DocQuad quad,
  int frameWidth,
  int frameHeight,
  int quarterTurns,
  double targetWidth,
  double targetHeight,
) {
  DocCorner map(double x, double y) {
    final w = frameWidth.toDouble();
    final h = frameHeight.toDouble();
    double dx;
    double dy;
    switch (quarterTurns) {
      case 1:
        dx = h - 1 - y;
        dy = x;
        break;
      case 2:
        dx = w - 1 - x;
        dy = h - 1 - y;
        break;
      case 3:
        dx = y;
        dy = w - 1 - x;
        break;
      default:
        dx = x;
        dy = y;
    }
    final dw = (quarterTurns == 1 || quarterTurns == 3) ? h : w;
    final dh = (quarterTurns == 1 || quarterTurns == 3) ? w : h;
    return DocCorner((dx / dw) * targetWidth, (dy / dh) * targetHeight);
  }

  return DocQuad(
    tl: map(quad.tl.x, quad.tl.y),
    tr: map(quad.tr.x, quad.tr.y),
    br: map(quad.br.x, quad.br.y),
    bl: map(quad.bl.x, quad.bl.y),
  );
}

Future<ui.Image> _toUiImage(img.Image src) async {
  final rgba = src.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba);
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    src.width,
    src.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

class _DocPreview extends StatelessWidget {
  const _DocPreview({required this.controller, required this.scan});

  final CameraController controller;
  final DocScanController scan;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, value, _) {
        final qT = _quarterTurnsFor(value.deviceOrientation);
        final isPortrait = qT == 1 || qT == 3;
        return AspectRatio(
          aspectRatio:
              isPortrait ? (1 / value.aspectRatio) : value.aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              RotatedBox(quarterTurns: qT, child: controller.buildPreview()),
              AnimatedBuilder(
                animation: scan,
                builder: (context, _) {
                  final quad = scan.currentQuad;
                  final frame = scan.latestFrame;
                  if (quad == null || frame == null) {
                    return const SizedBox.shrink();
                  }
                  return CustomPaint(
                    painter: _QuadPainter(
                      quad: quad,
                      frameWidth: frame.width.toDouble(),
                      frameHeight: frame.height.toDouble(),
                      quarterTurns: qT,
                      color: scan.isLocked
                          ? Colors.greenAccent
                          : Colors.amberAccent,
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _QuadPainter extends CustomPainter {
  _QuadPainter({
    required this.quad,
    required this.frameWidth,
    required this.frameHeight,
    required this.quarterTurns,
    required this.color,
  });

  final DocQuad quad;
  final double frameWidth;
  final double frameHeight;
  final int quarterTurns;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (frameWidth <= 0 || frameHeight <= 0 || size.isEmpty) return;
    final points = <Offset>[];
    for (final corner in quad.corners) {
      points.add(_toDisplay(corner.x, corner.y, size));
    }
    final path = Path()..addPolygon(points, true);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.18));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  Offset _toDisplay(double x, double y, Size size) {
    final w = frameWidth;
    final h = frameHeight;
    double dx;
    double dy;
    switch (quarterTurns) {
      case 1:
        dx = h - 1 - y;
        dy = x;
        break;
      case 2:
        dx = w - 1 - x;
        dy = h - 1 - y;
        break;
      case 3:
        dx = y;
        dy = w - 1 - x;
        break;
      default:
        dx = x;
        dy = y;
    }
    final dw = (quarterTurns == 1 || quarterTurns == 3) ? h : w;
    final dh = (quarterTurns == 1 || quarterTurns == 3) ? w : h;
    return Offset((dx / dw) * size.width, (dy / dh) * size.height);
  }

  @override
  bool shouldRepaint(covariant _QuadPainter oldDelegate) {
    return oldDelegate.quad != quad ||
        oldDelegate.quarterTurns != quarterTurns ||
        oldDelegate.color != color ||
        oldDelegate.frameWidth != frameWidth ||
        oldDelegate.frameHeight != frameHeight;
  }
}

class _ScanControls extends StatelessWidget {
  const _ScanControls({
    required this.isLocked,
    required this.isCapturing,
    required this.onCapture,
  });

  final bool isLocked;
  final bool isCapturing;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  isLocked
                      ? 'Documento detectado — capturá'
                      : 'Alineá el documento o capturá y ajustá a mano',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: 72,
                height: 72,
                child: FloatingActionButton(
                  backgroundColor: Colors.white,
                  onPressed: isCapturing ? null : onCapture,
                  child: isCapturing
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        )
                      : const Icon(Icons.camera_alt,
                          color: Colors.black, size: 32),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdjustScreen extends StatefulWidget {
  const _AdjustScreen({
    required this.image,
    required this.frameWidth,
    required this.frameHeight,
    required this.initialQuad,
  });

  final ui.Image image;
  final double frameWidth;
  final double frameHeight;
  final DocQuad initialQuad;

  @override
  State<_AdjustScreen> createState() => _AdjustScreenState();
}

class _AdjustScreenState extends State<_AdjustScreen> {
  late DocQuad _quad = widget.initialQuad;

  @override
  void dispose() {
    widget.image.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancelar',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Ajustá las esquinas'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_quad),
            child: const Text(
              'Listo',
              style: TextStyle(color: Colors.greenAccent),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: widget.frameWidth / widget.frameHeight,
                  child: QuadCornerEditor(
                    imageWidth: widget.frameWidth,
                    imageHeight: widget.frameHeight,
                    quad: _quad,
                    color: Colors.greenAccent,
                    onChanged: (q) => _quad = q,
                    child: RawImage(image: widget.image, fit: BoxFit.fill),
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Arrastrá las esquinas para ajustar el encuadre.',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DocumentosScreenState extends State<DocumentosScreen> {
  late final DocumentosRepository _repository;
  final ImagePicker _imagePicker = ImagePicker();
  final PendingPickerStorage _pendingPickerStorage =
      const PendingPickerStorage();
  final Map<int, XFile> _retryFiles = {};
  final Map<int, String> _retryIdempotencyKeys = {};
  final Map<int, String> _retryDescriptions = {};
  DocumentsPayload? _payload;
  bool _loading = true;
  String? _error;
  int? _uploadingTypeId;
  double _uploadProgress = 0;

  @override
  void initState() {
    super.initState();
    _repository = DocumentosRepository(widget.authController.api);
    _initialize();
  }

  Future<void> _initialize() async {
    await _load();
    if (mounted) await _recoverLostPickerData();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final payload = await _repository.getForFolder(widget.folderId);
      if (!mounted) return;
      setState(() => _payload = payload);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _recoverLostPickerData() async {
    try {
      final pending = await _pendingPickerStorage.read();
      if (pending == null || pending.folderId != widget.folderId || !mounted) {
        return;
      }

      final response = await _imagePicker.retrieveLostData();
      await _pendingPickerStorage.clear();
      if (response.isEmpty || !mounted) return;
      final files = response.files;
      if (response.exception != null && (files == null || files.isEmpty)) {
        _showMessage('No se pudo recuperar la imagen elegida.', error: true);
        return;
      }
      if (files == null || files.isEmpty) return;
      if (!widget.authController.canManageDocuments) {
        _showMessage(
          'Se recuperó una imagen pendiente, pero tu rol no permite cargar documentos.',
          error: true,
        );
        return;
      }

      final matchingTypes = _payload?.types
          .where((type) => type.active && type.id == pending.typeId)
          .toList(growable: false);
      if (matchingTypes == null || matchingTypes.isEmpty) {
        _showMessage(
          'El tipo de la imagen recuperada ya no está disponible.',
          error: true,
        );
        return;
      }

      final type = matchingTypes.first;
      final file = files.first;
      await _validateFile(file);
      final description = await _confirmUpload(type, file);
      if (description != null) {
        await _upload(
          type,
          file,
          idempotencyKey: _newUuidV4(),
          personalizedDescription: description.isEmpty ? null : description,
        );
      }
    } on ApiException catch (error) {
      _showMessage(error.message, error: true);
    } catch (_) {
      _showMessage('No se pudo recuperar la opción interrumpida.', error: true);
    }
  }

  Future<void> _chooseDocument(DocumentType type) async {
    if (_uploadingTypeId != null) return;
    final source = await showModalBottomSheet<_FileSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Elegir origen',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 5),
              Text(type.name, style: const TextStyle(color: Color(0xFF64748B))),
              const SizedBox(height: 18),
              _SourceTile(
                icon: Icons.document_scanner_outlined,
                title: 'Escanear documento',
                subtitle: 'Encuadre automático · captura automática o manual',
                onTap: () => Navigator.pop(context, _FileSource.camera),
              ),
              _SourceTile(
                icon: Icons.photo_library_outlined,
                title: 'Elegir de galería',
                subtitle: 'JPG o PNG guardado en el dispositivo',
                onTap: () => Navigator.pop(context, _FileSource.gallery),
              ),
              _SourceTile(
                icon: Icons.attach_file_rounded,
                title: 'Elegir archivo',
                subtitle: 'PDF, JPG o PNG de hasta 20 MB',
                onTap: () => Navigator.pop(context, _FileSource.files),
              ),
            ],
          ),
        ),
      ),
    );
    if (source == null || !mounted) return;

    try {
      final file = await _pickFile(source, type);
      if (file == null || !mounted) return;
      await _validateFile(file);
      final description = await _confirmUpload(type, file);
      if (description != null) {
        await _upload(
          type,
          file,
          idempotencyKey: _newUuidV4(),
          personalizedDescription: description.isEmpty ? null : description,
        );
      }
    } on ApiException catch (error) {
      _showMessage(error.message, error: true);
    } catch (_) {
      _showMessage('No se pudo abrir el archivo elegido.', error: true);
    }
  }

  Future<XFile?> _pickFile(_FileSource source, DocumentType type) async {
    switch (source) {
      case _FileSource.camera:
        return _scanDocument();
      case _FileSource.gallery:
        return _pickImage(ImageSource.gallery, type);
      case _FileSource.files:
        const group = XTypeGroup(
          label: 'Documentos de obra',
          extensions: ['pdf', 'jpg', 'jpeg', 'png'],
          mimeTypes: ['application/pdf', 'image/jpeg', 'image/png'],
        );
        return openFile(acceptedTypeGroups: [group]);
    }
  }

  Future<XFile?> _pickImage(ImageSource source, DocumentType type) async {
    await _pendingPickerStorage.write(
      folderId: widget.folderId,
      typeId: type.id,
    );
    try {
      final file = await _imagePicker.pickImage(
        source: source,
        imageQuality: 100,
        requestFullMetadata: false,
      );
      try {
        await _pendingPickerStorage.clear();
      } catch (_) {
        // La selección normal continúa; el dato residual no cambia de carpeta.
      }
      return file;
    } catch (_) {
      try {
        await _pendingPickerStorage.clear();
      } catch (_) {
        // Se preserva la excepción original del selector.
      }
      rethrow;
    }
  }

  Future<XFile?> _scanDocument() async {
    try {
      final scanned = await Navigator.of(context).push<_ScannedImage>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const _DocScannerScreen(),
        ),
      );
      if (scanned == null) return null;
      final target = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}${scanned.name}',
      );
      await target.writeAsBytes(scanned.bytes);
      return XFile(target.path, name: scanned.name, mimeType: 'image/png');
    } on PlatformException {
      return null;
    }
  }

  Future<void> _validateFile(XFile file) async {
    final extension = file.name.split('.').last.toLowerCase();
    if (!const {'pdf', 'jpg', 'jpeg', 'png'}.contains(extension)) {
      throw const ApiException('Elegí un PDF, JPG o PNG válido.');
    }
    final length = await file.length();
    final maxSize = _payload?.maxFileSize ?? AppConfig.maxDocumentBytes;
    if (length <= 0) {
      throw const ApiException('El archivo elegido está vacío.');
    }
    if (length > maxSize) {
      throw ApiException(
        'El archivo supera el máximo de ${_formatBytes(maxSize)}.',
      );
    }
  }

  Future<String?> _confirmUpload(DocumentType type, XFile file) async {
    final size = await file.length();
    if (!mounted) return null;
    final descriptionController = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) {
            final description = descriptionController.text.trim();
            final canConfirm =
                !type.requiresPersonalizedDescription || description.isNotEmpty;
            return AlertDialog(
              icon: const Icon(Icons.cloud_upload_outlined),
              title: Text(
                type.hasCurrent && !type.allowsMultipleCurrent
                    ? 'Cargar nueva versión'
                    : 'Cargar documento',
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    type.name,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          file.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _formatBytes(size),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (type.requiresPersonalizedDescription) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: descriptionController,
                      autofocus: true,
                      maxLength: 200,
                      textInputAction: TextInputAction.done,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Nombre del archivo *',
                        hintText: 'Ej.: Fotos del avance de obra',
                        helperText: 'Indicá a qué pertenece este documento.',
                      ),
                    ),
                  ],
                  if (type.hasCurrent && !type.allowsMultipleCurrent) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'La versión actual quedará conservada en el historial.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancelar'),
                ),
                FilledButton.icon(
                  onPressed: canConfirm
                      ? () => Navigator.pop(context, description)
                      : null,
                  icon: const Icon(Icons.upload_rounded),
                  label: const Text('Confirmar carga'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      descriptionController.dispose();
    }
  }

  Future<void> _upload(
    DocumentType type,
    XFile file, {
    required String idempotencyKey,
    String? personalizedDescription,
  }) async {
    setState(() {
      _uploadingTypeId = type.id;
      _uploadProgress = 0;
    });
    try {
      await _repository.upload(
        folderId: widget.folderId,
        typeId: type.id,
        idempotencyKey: idempotencyKey,
        file: file,
        personalizedDescription: personalizedDescription,
        onProgress: (progress) {
          if (mounted) setState(() => _uploadProgress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _retryFiles.remove(type.id);
        _retryIdempotencyKeys.remove(type.id);
        _retryDescriptions.remove(type.id);
      });
      _showMessage('${type.name} se cargó correctamente.');
      await _loadWithoutSpinner();
    } on ApiException catch (error) {
      if (!mounted) return;
      final fileUnavailable = error.code == 'local_file_unavailable';
      setState(() {
        if (fileUnavailable) {
          _retryFiles.remove(type.id);
          _retryIdempotencyKeys.remove(type.id);
          _retryDescriptions.remove(type.id);
        } else {
          _retryFiles[type.id] = file;
          _retryIdempotencyKeys[type.id] = idempotencyKey;
          if (personalizedDescription != null) {
            _retryDescriptions[type.id] = personalizedDescription;
          } else {
            _retryDescriptions.remove(type.id);
          }
        }
      });
      _showMessage(
        fileUnavailable
            ? error.message
            : '${error.message} Podés reintentar sin volver a elegir el archivo.',
        error: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _uploadingTypeId = null;
          _uploadProgress = 0;
        });
      }
    }
  }

  Future<void> _loadWithoutSpinner() async {
    try {
      final payload = await _repository.getForFolder(widget.folderId);
      if (mounted) setState(() => _payload = payload);
    } on ApiException catch (error) {
      if (mounted) _showMessage(error.message, error: true);
    }
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error
            ? Theme.of(context).colorScheme.error
            : const Color(0xFF198754),
      ),
    );
  }

  void _showHistory(DocumentType type) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        maxChildSize: 0.9,
        minChildSize: 0.35,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
          children: [
            Text(
              'Historial · ${type.name}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 5),
            const Text(
              'Versiones anteriores y documentos dados de baja.',
              style: TextStyle(color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 16),
            for (final document in type.history)
              _HistoryTile(
                document: document,
                onPreview: () => _previewDocument(document),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _previewDocument(DocumentRecord document) async {
    final folderId = _payload?.folder.id;
    if (folderId == null) return;
    if (!document.downloadable) {
      _showMessage(
        'Este documento todavía no está disponible para ver.',
        error: true,
      );
      return;
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Dialog(
        child: Padding(
          padding: EdgeInsets.all(22),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              SizedBox(width: 16),
              Flexible(child: Text('Descargando documento…')),
            ],
          ),
        ),
      ),
    );
    try {
      final bytes = await _repository.downloadDocument(
        folderId: folderId,
        documentId: document.id,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _FilePreviewScreen(
            bytes: bytes,
            document: document,
          ),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) Navigator.of(context).pop();
      _showMessage(e.message, error: true);
    } catch (_) {
      if (mounted) Navigator.of(context).pop();
      _showMessage('No se pudo abrir el documento.', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = _payload;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              payload == null
                  ? widget.fallbackTitle
                  : '${payload.folder.year} · ${payload.folder.procedure}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const Text(
              'Documentación',
              style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _DocumentError(message: _error!, onRetry: _load)
          : payload == null
          ? const SizedBox.shrink()
          : RefreshIndicator(
              onRefresh: _loadWithoutSpinner,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  _FolderHeader(
                    folder: payload.folder,
                    complete: payload.types
                        .where((type) => type.isRequired && type.hasCurrent)
                        .length,
                    total: payload.types
                        .where((type) => type.isRequired)
                        .length,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Tipos documentales',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Los tipos normales tienen historial; Otros puede tener varios vigentes.',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${payload.types.length} tipos',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF64748B),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (final type in payload.types) ...[
                    _DocumentTypeCard(
                      type: type,
                      canManage:
                          widget.authController.canManageDocuments &&
                          type.active,
                      uploading: _uploadingTypeId == type.id,
                      progress: _uploadingTypeId == type.id
                          ? _uploadProgress
                          : 0,
                      retryAvailable:
                          _retryFiles.containsKey(type.id) &&
                          _retryIdempotencyKeys.containsKey(type.id),
                      onChoose: () => _chooseDocument(type),
                      onRetry: () => _upload(
                        type,
                        _retryFiles[type.id]!,
                        idempotencyKey: _retryIdempotencyKeys[type.id]!,
                        personalizedDescription: _retryDescriptions[type.id],
                      ),
                      onHistory: () => _showHistory(type),
                      onPreview: _previewDocument,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (!widget.authController.canManageDocuments)
                    const _ReadOnlyNotice(),
                ],
              ),
            ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    leading: Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        icon,
        color: Theme.of(context).colorScheme.onPrimaryContainer,
      ),
    ),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: onTap,
  );
}

class _FolderHeader extends StatelessWidget {
  const _FolderHeader({
    required this.folder,
    required this.complete,
    required this.total,
  });
  final DocumentFolder folder;
  final int complete;
  final int total;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.primary,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    child: Padding(
      padding: const EdgeInsets.all(19),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.folder_copy_outlined,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$complete/$total obligatorios',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '${folder.year} · ${folder.procedure}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${folder.address}, ${folder.locality}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: .82),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'Cuenta ${folder.municipalAccount}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: .72),
              fontSize: 11,
            ),
          ),
        ],
      ),
    ),
  );
}

class _DocumentTypeCard extends StatelessWidget {
  const _DocumentTypeCard({
    required this.type,
    required this.canManage,
    required this.uploading,
    required this.progress,
    required this.retryAvailable,
    required this.onChoose,
    required this.onRetry,
    required this.onHistory,
    required this.onPreview,
  });

  final DocumentType type;
  final bool canManage;
  final bool uploading;
  final double progress;
  final bool retryAvailable;
  final VoidCallback onChoose;
  final VoidCallback onRetry;
  final VoidCallback onHistory;
  final ValueChanged<DocumentRecord> onPreview;

  @override
  Widget build(BuildContext context) {
    final current = type.current;
    final currentDocument = current;
    final currentDocuments = type.currentDocuments;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 41,
                  height: 41,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.description_outlined,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        type.isRequired ? type.name : '${type.name} · Opcional',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        type.description,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _StatusPill(
                  available: type.hasCurrent,
                  optional: !type.isRequired,
                  version: current?.version,
                  availableLabel: type.allowsMultipleCurrent && type.hasCurrent
                      ? '${currentDocuments.length} vigente${currentDocuments.length == 1 ? '' : 's'}'
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 15),
            if (!type.hasCurrent)
              Container(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.file_present_outlined,
                      color: Color(0xFF94A3B8),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Sin documento vigente',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            type.isRequired
                                ? 'Cargá la primera versión para completar este tipo.'
                                : 'Documento opcional. Cargalo si corresponde.',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              )
            else if (type.allowsMultipleCurrent)
              Column(
                children: [
                  for (final document in currentDocuments)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _CurrentDocumentTile(
                  document: document,
                  onPreview: () => onPreview(document),
                ),
                    ),
                ],
              )
            else
              Container(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  children: [
                    Icon(
                      currentDocument!.extension == 'pdf'
                          ? Icons.picture_as_pdf_outlined
                          : Icons.image_outlined,
                      color: currentDocument.extension == 'pdf'
                          ? const Color(0xFFDC2626)
                          : theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            currentDocument.originalName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'v${currentDocument.version} · ${_formatBytes(currentDocument.finalSize)} · ${_formatDate(currentDocument.availableAt ?? currentDocument.createdAt)}',
                            style: const TextStyle(
                              fontSize: 9,
                              color: Color(0xFF64748B),
                            ),
                          ),
                          if (currentDocument.savedPercent > 0)
                            Text(
                              '${currentDocument.savedPercent}% menos luego de optimizar',
                              style: const TextStyle(
                                fontSize: 9,
                                color: Color(0xFF198754),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ),
                    _EyeButton(
                      document: currentDocument,
                      onPreview: () => onPreview(currentDocument),
                    ),
                  ],
                ),
              ),
            if (uploading) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress > 0 && progress < 1 ? progress : null,
                  minHeight: 7,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                progress < 1
                    ? 'Subiendo ${(progress * 100).round()}%'
                    : 'Procesando y guardando...',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF64748B),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                if (type.history.isNotEmpty)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: uploading ? null : onHistory,
                      icon: const Icon(Icons.history_rounded, size: 18),
                      label: Text('Historial (${type.history.length})'),
                    ),
                  )
                else
                  const Spacer(),
                if (type.history.isNotEmpty && canManage)
                  const SizedBox(width: 9),
                if (canManage)
                  Expanded(
                    child: retryAvailable
                        ? FilledButton.icon(
                            onPressed: uploading ? null : onRetry,
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: const Text('Reintentar'),
                          )
                        : FilledButton.icon(
                            onPressed: uploading ? null : onChoose,
                            icon: const Icon(
                              Icons.add_a_photo_outlined,
                              size: 18,
                            ),
                            label: Text(
                              type.allowsMultipleCurrent
                                  ? 'Agregar documento'
                                  : type.hasCurrent
                                  ? 'Nueva versión'
                                  : 'Cargar',
                            ),
                          ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrentDocumentTile extends StatelessWidget {
  const _CurrentDocumentTile({
    required this.document,
    required this.onPreview,
  });

  final DocumentRecord document;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = document.personalizedDescription?.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Icon(
            document.extension == 'pdf'
                ? Icons.picture_as_pdf_outlined
                : Icons.image_outlined,
            color: document.extension == 'pdf'
                ? const Color(0xFFDC2626)
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title == null || title.isEmpty
                      ? document.originalName
                      : title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  document.originalName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF475569),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'v${document.version} · ${_formatBytes(document.finalSize)} · ${_formatDate(document.availableAt ?? document.createdAt)}',
                  style: const TextStyle(fontSize: 9, color: Color(0xFF64748B)),
                ),
              ],
            ),
          ),
          _EyeButton(document: document, onPreview: onPreview),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.available,
    required this.optional,
    this.version,
    this.availableLabel,
  });
  final bool available;
  final bool optional;
  final int? version;
  final String? availableLabel;

  @override
  Widget build(BuildContext context) {
    final label = available
        ? availableLabel ?? 'Vigente · v$version'
        : optional
        ? 'Opcional'
        : 'Pendiente';
    final backgroundColor = available
        ? const Color(0xFFE8F7EF)
        : optional
        ? const Color(0xFFEFF6FF)
        : const Color(0xFFF1F5F9);
    final foregroundColor = available
        ? const Color(0xFF198754)
        : optional
        ? const Color(0xFF2563EB)
        : const Color(0xFF64748B);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: foregroundColor,
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.document,
    required this.onPreview,
  });

  final DocumentRecord document;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final status = switch (document.status) {
      'eliminado' => 'Dado de baja',
      'error' => 'Carga incompleta',
      'purgado' => 'Retención vencida',
      _ => 'Versión anterior',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 9),
      child: ListTile(
        leading: CircleAvatar(
          child: Text(
            'v${document.version}',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
          ),
        ),
        title: Text(
          document.originalName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '$status · ${_formatBytes(document.finalSize)}\n${_formatDate(document.createdAt)}',
          style: const TextStyle(fontSize: 10),
        ),
        isThreeLine: true,
        trailing: _EyeButton(document: document, onPreview: onPreview),
      ),
    );
  }
}

class _EyeButton extends StatelessWidget {
  const _EyeButton({
    required this.document,
    required this.onPreview,
  });

  final DocumentRecord document;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    if (!document.downloadable) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: IconButton(
        onPressed: onPreview,
        tooltip: 'Ver documento',
        icon: const Icon(Icons.visibility_outlined, size: 20),
        color: const Color(0xFF475569),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      ),
    );
  }
}

class _FilePreviewScreen extends StatelessWidget {
  const _FilePreviewScreen({
    required this.bytes,
    required this.document,
  });

  final Uint8List bytes;
  final DocumentRecord document;

  @override
  Widget build(BuildContext context) {
    if (_isImageExtension(document.extension)) {
      return _buildImage(context);
    }
    return _buildFile(context);
  }

  Widget _buildImage(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          InteractiveViewer(
            maxScale: 6,
            child: Center(
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton.filledTonal(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Cerrar',
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '${document.originalName}\n${_formatBytes(bytes.length)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFile(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          document.originalName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.picture_as_pdf_outlined,
                size: 72,
                color: Color(0xFFDC2626),
              ),
              const SizedBox(height: 14),
              Text(
                document.originalName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _formatBytes(bytes.length),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 4),
              const Text(
                'Este documento es un PDF. Podes abrirlo con otra aplicación.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => _openExternally(context),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Abrir con otra aplicación'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openExternally(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final extension = document.extension.toLowerCase();
      final path =
          '${Directory.systemTemp.path}${Platform.pathSeparator}gis_doc_${document.id}.$extension';
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);
      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done) {
        throw const ApiException('open_failed');
      }
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el archivo.')),
      );
    }
  }
}

bool _isImageExtension(String extension) {
  switch (extension.toLowerCase()) {
    case 'jpg':
    case 'jpeg':
    case 'png':
    case 'gif':
    case 'bmp':
    case 'webp':
      return true;
    default:
      return false;
  }
}

class _ReadOnlyNotice extends StatelessWidget {
  const _ReadOnlyNotice();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF7E6),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFFF5D78E)),
    ),
    child: const Row(
      children: [
        Icon(Icons.visibility_outlined, color: Color(0xFF9A6700)),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'Modo consulta: tu rol puede ver la documentación, pero no cargar nuevos archivos.',
            style: TextStyle(
              fontSize: 11,
              color: Color(0xFF7A5200),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

class _DocumentError extends StatelessWidget {
  const _DocumentError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 14),
          const Text(
            'No pudimos cargar la documentación',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 7),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Reintentar'),
          ),
        ],
      ),
    ),
  );
}

String _newUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _formatDate(DateTime? value) => value == null
    ? 'Sin fecha'
    : DateFormat('dd/MM/yyyy · HH:mm', 'es_AR').format(value);
