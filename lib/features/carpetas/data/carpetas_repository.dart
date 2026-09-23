import '../../../core/api/api_client.dart';
import '../models/carpeta_obra.dart';

class CarpetasRepository {
  const CarpetasRepository(this._api);

  final ApiClient _api;

  Future<CarpetasPage> list({
    required int page,
    String search = '',
    int pageSize = 20,
  }) async {
    final response = await _api.getJson(
      'carpeta-obras',
      query: {
        'page': page,
        'pageSize': pageSize,
        if (search.trim().isNotEmpty) 'search': search.trim(),
      },
    );
    return CarpetasPage.fromJson(response);
  }
}
