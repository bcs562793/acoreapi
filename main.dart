// nesine_ws_test.dart v4
// GetLiveBetResults → futbol maçlarını göster + alan isimlerini öğren

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
  if (res.statusCode != 200 || res.body.isEmpty) {
    print('Hata: ${res.body.substring(0, res.body.length.clamp(0, 300))}');
    exit(1);
  }

  final data = jsonDecode(res.body);
  if (data is! Map) { print('Map değil: ${res.body.substring(0,200)}'); exit(1); }

  // Futbol maçlarını filtrele
  final football = <dynamic>[];
  data.forEach((key, val) {
    if (val is Map) {
      final sport = (val['SportType'] ?? val['BettingType'] ?? '').toString();
      final btip  = val['BTIP'] ?? val['SportId'] ?? 0;
      // BTIP=1 genellikle futbol
      if (sport.toLowerCase().contains('football') || 
          sport.toLowerCase().contains('futbol') ||
          btip == 1 || btip == '1') {
        football.add(val);
      }
    }
  });

  print('Toplam: ${data.length} maç | Futbol: ${football.length}\n');

  // İlk futbol maçının TÜM alanlarını göster
  if (football.isNotEmpty) {
    print('=== İlk futbol maçı (tüm alanlar) ===');
    final first = football.first as Map;
    first.forEach((k, v) {
      print('  $k: $v');
    });
  } else {
    // Futbol bulunamazsa tüm sport type'larını göster
    print('=== Mevcut sport type\'lar ===');
    final sports = <String, int>{};
    data.forEach((key, val) {
      if (val is Map) {
        final s = (val['SportType'] ?? val['BTIP'] ?? 'unknown').toString();
        sports[s] = (sports[s] ?? 0) + 1;
      }
    });
    sports.forEach((k, v) => print('  $k: $v maç'));

    print('\n=== İlk maç (tüm alanlar) ===');
    final first = data.values.first as Map;
    first.forEach((k, v) => print('  $k: $v'));
  }

  // NID alanı var mı? — fixture eşleştirmesi için
  print('\n=== NID ve BID kontrolü ===');
  int withNid = 0, withBid = 0;
  data.forEach((key, val) {
    if (val is Map) {
      if (val.containsKey('NID')) withNid++;
      if (val.containsKey('BID')) withBid++;
    }
  });
  print('NID olan: $withNid | BID olan: $withBid');

  exit(0);
}
