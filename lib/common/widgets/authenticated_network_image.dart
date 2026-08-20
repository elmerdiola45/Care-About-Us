import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Renders an authenticated image (one requiring a Bearer token) by
/// fetching its bytes with an explicit `Authorization` header and drawing
/// them via [Image.memory], instead of `Image.network(url, headers: {...})`.
///
/// Flutter Web does not reliably send custom HTTP headers on
/// `Image.network` requests — the browser's underlying image-loading
/// mechanism frequently ignores them — so an auth-protected image URL
/// silently 401s and always falls through to the error state on web, even
/// though the same code works on mobile/desktop. Fetching the bytes
/// ourselves works identically on every platform.
class AuthenticatedNetworkImage extends StatefulWidget {
  const AuthenticatedNetworkImage({
    super.key,
    required this.imageUrl,
    required this.token,
    this.width,
    this.height,
    this.fit,
    required this.errorWidget,
  });

  final String imageUrl;
  final String? token;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final Widget errorWidget;

  @override
  State<AuthenticatedNetworkImage> createState() =>
      _AuthenticatedNetworkImageState();
}

class _AuthenticatedNetworkImageState
    extends State<AuthenticatedNetworkImage> {
  late Future<Uint8List> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  @override
  void didUpdateWidget(covariant AuthenticatedNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.token != widget.token) {
      _future = _fetch();
    }
  }

  Future<Uint8List> _fetch() async {
    final response = await http.get(
      Uri.parse(widget.imageUrl),
      headers: {
        if (widget.token != null && widget.token!.isNotEmpty)
          'Authorization': 'Bearer ${widget.token}',
      },
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to load image: HTTP ${response.statusCode}');
    }
    return response.bodyBytes;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SizedBox(
            width: widget.width,
            height: widget.height,
            child: const Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return widget.errorWidget;
        }
        return Image.memory(
          snapshot.data!,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          errorBuilder: (context, error, stackTrace) => widget.errorWidget,
        );
      },
    );
  }
}
