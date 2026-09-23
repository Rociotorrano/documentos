class ApiException implements Exception {
  const ApiException(
    this.message, {
    this.statusCode,
    this.details = const [],
    this.code,
  });

  final String message;
  final int? statusCode;
  final List<String> details;
  final String? code;

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}
