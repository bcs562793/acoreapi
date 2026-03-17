import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

final _headers = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/122.0.0.0',
  'Accept': 'application/json, text/javascript, */*; q=0.01',
  'Accept-Language': 'tr-TR,tr;q=0.9',
  'Referer': 'https://www.nesine.com/iddaa/canli-iddaa-canli-bahis',
  'X-Requested-With': 'XMLHttpRequest',
  'Origin': 'https://www.nesine.com',
};

Future<void> main() async {
  print('📡 GetLiveBetResults...\n');

  final res = await http.post(
    Uri.parse('https://www.nesine.com/LiveScore/GetLiveBetResults'),
    headers: _headers,
  ).timeout(const Duration(seconds: 10));

  print('HTTP ${res.statusCode} | ${res.body.length} bytes\n');

  final data = jsonDecode(res.body) as List;
  print('Toplam: ${data.length} maç\n');

  // İlk maçın TÜM alanlarını göster
  if (data.isNotEmpty) {
    print('=== İlk maç (tüm alanlar) ===');
    final first = data.first as Map;
    first.forEach((k, v) {
      // EventScores varsa içini göster
      if (k == 'EventScores' && v is List && v.isNotEmpty) {
        print('  $k: ${v.take(3).toList()}');
      } else if (v.toString().length < 200) {
        print('  $k: $v');
      } else {
        print('  $k: ${v.toString().substring(0, 150)}...');
      }
    });
  }

  // BID / MatchId / NID dağılımı
  print('\n=== Alan kontrolü ===');
  final keys = <String>{};
  for (final item in data.take(5)) {
    if (item is Map) keys.addAll(item.keys.cast<String>());
  }
  print('Mevcut alanlar: $keys');

  // Status=15 dışında aktif maçları bul
  final active = data.where((m) {
    if (m is! Map) return false;
    final st = m['Status'] ?? m['ST'] ?? 0;
    return st != 15 && st != '15'; // 15=bitmemiş NS olabilir
  }).toList();
  print('\nStatus!=15 maç sayısı: ${active.length}');
  if (active.isNotEmpty) {
    print('Aktif maç örneği:');
    final a = active.first as Map;
    a.forEach((k, v) => print('  $k: $v'));
  }

  // BID ile eşleşme: MatchId == WS'den gelen BID mi?
  print('\n=== MatchId örnekleri ===');
  for (final m in data.take(5)) {
    if (m is Map) {
      print('  MatchId=${m['MatchId']} BetradarId=${m['BetradarId']} Status=${m['Status']}');
    }
  }

  exit(0);
}
