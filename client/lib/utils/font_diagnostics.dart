/// One-shot startup font diagnostics.
///
/// Linux renders CJK through the system font stack, so a broken fallback shows
/// up as blank glyphs. Measuring and rasterising a CJK sample separates "no
/// glyphs at all" from "glyphs laid out but never painted".

import "dart:io" show Platform;
import "dart:ui" as ui;

import "package:flutter/material.dart";

import "../services/logger_service.dart";

Future<void> logFontDiagnostics() async {
  try {
    final report = <String>[];
    for (final sample in const {"ascii": "Steam", "cjk": "游戏下载目录"}.entries) {
      final result = await _measure(sample.value);
      report.add(
        "${sample.key}(width=${result.width.toStringAsFixed(1)},"
        "painted=${result.painted})",
      );
    }
    LoggerService().info(
      "font diagnostic: locale=${Platform.localeName} "
      "dispatcherLocale=${ui.PlatformDispatcher.instance.locale} "
      "${report.join(' ')}",
    );
  } catch (e) {
    LoggerService().warn("font diagnostic failed", e);
  }
}

class _Measurement {
  const _Measurement(this.width, this.painted);

  final double width;
  final int painted;
}

Future<_Measurement> _measure(String text) async {
  final painter = TextPainter(
    text: TextSpan(text: text, style: const TextStyle(fontSize: 16)),
    textDirection: TextDirection.ltr,
  )..layout();

  final width = painter.width;
  final height = painter.height;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, Offset.zero);
  painter.dispose();
  final picture = recorder.endRecording();

  final image = await picture.toImage(
    width.ceil().clamp(1, 2048),
    height.ceil().clamp(1, 2048),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  picture.dispose();
  image.dispose();

  var painted = 0;
  final bytes = data?.buffer.asUint8List();
  if (bytes != null) {
    for (var i = 3; i < bytes.length; i += 4) {
      if (bytes[i] != 0) painted++;
    }
  }
  return _Measurement(width, painted);
}
