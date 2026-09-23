class AuthUser {
  const AuthUser({
    required this.id,
    required this.username,
    required this.role,
    required this.isSuperAdmin,
    this.firstName,
    this.lastName,
    this.email,
  });

  final int id;
  final String username;
  final String role;
  final bool isSuperAdmin;
  final String? firstName;
  final String? lastName;
  final String? email;

  String get displayName {
    final fullName = [firstName, lastName]
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .join(' ');
    return fullName.isEmpty ? username : fullName;
  }

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
    id: _asInt(json['id']),
    username: json['usuario']?.toString() ?? '',
    role: json['rol']?.toString() ?? 'Sin rol',
    isSuperAdmin: json['superadmin'] == true,
    firstName: json['nombre']?.toString(),
    lastName: json['apellido']?.toString(),
    email: json['email']?.toString(),
  );

  static int _asInt(Object? value) =>
      int.tryParse(value?.toString() ?? '') ?? 0;
}
