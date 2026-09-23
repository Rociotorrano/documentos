abstract final class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api2.geo.lacosta.gob.ar/api',
  );

  static const int maxDocumentBytes = 20 * 1024 * 1024;
  static const Duration requestTimeout = Duration(seconds: 35);
  static const Duration uploadTimeout = Duration(minutes: 3);

  static Uri apiUri(String endpoint, [Map<String, Object?>? query]) {
    final base = apiBaseUrl.replaceFirst(RegExp(r'/+$'), '');
    final path = endpoint.replaceFirst(RegExp(r'^/+'), '');
    final uri = Uri.parse('$base/$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(
      queryParameters: {
        for (final entry in query.entries)
          if (entry.value != null && entry.value.toString().isNotEmpty)
            entry.key: entry.value.toString(),
      },
    );
  }
}
