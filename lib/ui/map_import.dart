import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

import '../trip/imports/geo_import.dart';
import '../trip/imports/map_layers.dart';
import '../trip/trip_controller.dart';
import 'overlay_place_page.dart';

/// Pick a GPX / KML / KMZ / MBTiles / image / PDF file and import it.
Future<MapLayer?> pickAndImportMap(
  BuildContext context,
  TripController trip,
) async {
  final List<PlatformFile> files;
  try {
    files = await FilePicker.pickFiles(dialogTitle: 'Import a map or trail');
  } catch (e) {
    if (context.mounted) _snack(context, 'Could not open the file picker: $e');
    return null;
  }
  if (files.isEmpty || !context.mounted) return null;
  final f = files.first;
  final tmp = await _tempFile(f.name);
  try {
    final sink = tmp.openWrite();
    await sink.addStream(f.readAsByteStream());
    await sink.close();
  } catch (e) {
    if (context.mounted) _snack(context, 'Could not read ${f.name}: $e');
    return null;
  }
  if (!context.mounted) return null;
  return importMapFile(context, trip, tmp, f.name, temporary: true);
}

Future<File> _tempFile(String name) async {
  final d = Directory('${(await getTemporaryDirectory()).path}/imports');
  await d.create(recursive: true);
  final safe = name.replaceAll(RegExp(r'[^\w.\- ]'), '_');
  return File(
    '${d.path}/${DateTime.now().microsecondsSinceEpoch}_'
    '${safe.isEmpty ? 'file' : safe}',
  );
}

/// Import [file] (a picked file or one shared to the app with "Open with").
/// [temporary] files are deleted afterwards (MBTiles are moved instead).
Future<MapLayer?> importMapFile(
  BuildContext context,
  TripController trip,
  File file,
  String name, {
  bool temporary = false,
}) async {
  final layers = trip.layers;
  final size = await file.length();
  final head = await _head(file);
  final kind = sniffImport(name, head);
  final base = name
      .split(RegExp(r'[/\\]'))
      .last
      .replaceFirst(RegExp(r'\.[A-Za-z0-9]+$'), '');
  if (!context.mounted) return null;
  final busy = _Busy.show(context, 'Importing ${formatBytes(size)}…');
  MapLayer? l;
  var moved = false;
  try {
    switch (kind) {
      case ImportKind.gpx:
      case ImportKind.kml:
      case ImportKind.kmz:
        l = await layers.importTrail(name, await file.readAsBytes());
      case ImportKind.mbtiles:
        l = await layers.importMbtiles(file, move: temporary);
        moved = temporary;
      case ImportKind.image:
        if (size > MapLayers.maxImageBytes) {
          throw StorageLimitException(
            'Image too big (${formatBytes(size)}; up to '
            '${formatBytes(MapLayers.maxImageBytes)})',
          );
        }
        final ext = name.contains('.') ? name.split('.').last : 'png';
        l = await layers.importOverlay(
          base,
          await file.readAsBytes(),
          ext: ext,
        );
      case ImportKind.pdf:
        if (size > MapLayers.maxPdfBytes) {
          throw StorageLimitException(
            'PDF too big (${formatBytes(size)}; up to '
            '${formatBytes(MapLayers.maxPdfBytes)})',
          );
        }
        final png = await renderPdfFirstPage(file.path);
        l = await layers.importOverlay(base, png, sourceBytes: size);
      case null:
        throw ImportFormatException(
          'Not a file the map can use. Import GPX, KML, KMZ, MBTiles, a '
          'PNG / JPEG / WebP image or a PDF.',
        );
    }
  } catch (e) {
    busy.close();
    if (context.mounted) _snack(context, 'Import failed: $e');
    return null;
  } finally {
    if (temporary && !moved) {
      unawaited(file.delete().then((_) {}, onError: (_) {}));
    }
  }
  busy.close();
  if (!context.mounted) return l;
  switch (l.kind) {
    case MapLayerKind.trail:
      _snack(
        context,
        'Imported ${l.name}: ${l.summary} (${formatBytes(l.bytes)}).',
      );
    case MapLayerKind.tiles:
      await trip.update((s) => s.mapSource = 'mbtiles:${l!.id}');
      if (context.mounted) {
        _snack(
          context,
          'Offline map ${l.name} (${formatBytes(l.bytes)}) is now the base map.',
        );
      }
    case MapLayerKind.overlay:
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => OverlayPlacePage(trip: trip, layer: l!),
        ),
      );
  }
  return l;
}

Future<List<int>> _head(File f) async {
  final r = await f.open();
  try {
    return await r.read(1024);
  } finally {
    await r.close();
  }
}

/// Page 1 of a PDF as a PNG (about 3000 px on the long side, white
/// background) so it can be placed like an image.
Future<Uint8List> renderPdfFirstPage(String path) async {
  final doc = await PdfDocument.openFile(path);
  try {
    final page = await doc.getPage(1);
    try {
      final long = max(page.width, page.height);
      final scale = (3000 / long).clamp(0.5, 6.0);
      final img = await page.render(
        width: (page.width * scale).roundToDouble(),
        height: (page.height * scale).roundToDouble(),
        format: PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      if (img == null) throw ImportFormatException('Could not draw the PDF');
      return img.bytes;
    } finally {
      await page.close();
    }
  } finally {
    await doc.close();
  }
}

void _snack(BuildContext context, String s) =>
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(s)));

class _Busy {
  _Busy(this._nav);
  final NavigatorState _nav;
  bool _open = true;

  static _Busy show(BuildContext context, String text) {
    final b = _Busy(Navigator.of(context));
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 16),
                Expanded(child: Text(text)),
              ],
            ),
          ),
        ),
      ).then((_) => b._open = false),
    );
    return b;
  }

  void close() {
    if (_open) {
      _open = false;
      _nav.pop();
    }
  }
}
