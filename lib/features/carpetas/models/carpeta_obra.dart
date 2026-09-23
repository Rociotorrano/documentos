class CarpetaObra {
  const CarpetaObra({
    required this.id,
    required this.year,
    required this.procedure,
    required this.address,
    required this.locality,
    required this.municipalAccount,
    required this.workType,
    required this.destination,
    required this.owners,
  });

  final int id;
  final int year;
  final String procedure;
  final String address;
  final String locality;
  final String municipalAccount;
  final String workType;
  final String destination;
  final List<String> owners;

  String get primaryOwner =>
      owners.isEmpty ? 'Sin titular informado' : owners.first;

  factory CarpetaObra.fromJson(Map<String, dynamic> json) {
    final rawOwners = json['propietarios'];
    final owners = rawOwners is List
        ? rawOwners
              .whereType<Map>()
              .map((owner) {
                final lastName = owner['apellido']?.toString().trim() ?? '';
                final firstName = owner['nombre']?.toString().trim() ?? '';
                return [
                  lastName,
                  firstName,
                ].where((part) => part.isNotEmpty).join(', ');
              })
              .where((name) => name.isNotEmpty)
              .toList()
        : <String>[];
    return CarpetaObra(
      id: int.tryParse(json['id']?.toString() ?? '') ?? 0,
      year: int.tryParse(json['anio']?.toString() ?? '') ?? 0,
      procedure: json['tramite']?.toString() ?? '',
      address: json['direccion']?.toString() ?? '',
      locality: json['localidad']?.toString() ?? '',
      municipalAccount: json['cuentaMunicipal']?.toString() ?? '',
      workType: json['tipoObra']?.toString() ?? '',
      destination: json['destino']?.toString() ?? '',
      owners: owners,
    );
  }
}

class CarpetasPage {
  const CarpetasPage({
    required this.items,
    required this.page,
    required this.totalPages,
    required this.total,
  });

  final List<CarpetaObra> items;
  final int page;
  final int totalPages;
  final int total;

  factory CarpetasPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final pagination = json['pagination'];
    final pageData = pagination is Map ? pagination : const <String, dynamic>{};
    return CarpetasPage(
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) =>
                      CarpetaObra.fromJson(Map<String, dynamic>.from(item)),
                )
                .toList()
          : const [],
      page: int.tryParse(pageData['page']?.toString() ?? '') ?? 1,
      totalPages: int.tryParse(pageData['totalPages']?.toString() ?? '') ?? 0,
      total: int.tryParse(pageData['total']?.toString() ?? '') ?? 0,
    );
  }
}
