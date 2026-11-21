import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/game.dart';
import '../services/api_client.dart';
import '../services/logger_service.dart';
import 'nsfw_image.dart';

class LibraryCover extends StatefulWidget {
  final GameSummary game;
  final String baseUrl;
  final WidgetBuilder placeholder;

  const LibraryCover({
    super.key,
    required this.game,
    required this.baseUrl,
    required this.placeholder,
  });

  @override
  State<LibraryCover> createState() => _LibraryCoverState();
}

class _LibraryCoverState extends State<LibraryCover> {
  String? _reportedUrl;

  Widget _error(BuildContext context, String url, Object error) {
    if (_reportedUrl != url) {
      _reportedUrl = url;
      final reason = error is NetworkImageLoadException
          ? 'HTTP ${error.statusCode}'
          : '${error.runtimeType}';
      LoggerService().warn('游戏库封面加载失败: game=${widget.game.id} reason=$reason');
    }
    return widget.placeholder(context);
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final name = game.coverPath?.replaceAll('\\', '/').split('/').last;
    if (name == null || name.isEmpty || widget.baseUrl.isEmpty) {
      return widget.placeholder(context);
    }
    final url = Uri.parse(widget.baseUrl)
        .replace(
          pathSegments: ['api', 'files', 'covers', name],
          queryParameters: {'t': game.coverRevision ?? game.importedAt},
        )
        .toString();
    final headers = mediaHeadersFor(url);
    return NsfwImage(
      isNsfw: game.isNsfw,
      child: defaultTargetPlatform == TargetPlatform.android
          ? LayoutBuilder(
              builder: (context, size) {
                final width =
                    size.maxWidth * MediaQuery.devicePixelRatioOf(context);
                return Image.network(
                  url,
                  key: ValueKey(url),
                  headers: headers,
                  fit: BoxFit.cover,
                  cacheWidth: width.isFinite && width >= 1
                      ? width.ceil()
                      : null,
                  frameBuilder: (context, image, frame, sync) =>
                      frame == null && !sync
                      ? widget.placeholder(context)
                      : image,
                  errorBuilder: (context, error, _) =>
                      _error(context, url, error),
                );
              },
            )
          : CachedNetworkImage(
              imageUrl: url,
              httpHeaders: headers,
              fit: BoxFit.cover,
              placeholder: (context, _) => widget.placeholder(context),
              errorWidget: (context, _, error) => _error(context, url, error),
            ),
    );
  }
}
