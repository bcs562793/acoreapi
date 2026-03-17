// sync.dart — GitHub Actions cron ile çalışır
// Nesine maç listesi → Supabase nesine_bid güncelle

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

final _sbUrl = Platform.environment['SUPABASE_URL'] ?? '';
final _sbKey = Platform.environment['SUPABASE_KEY'] ?? '';
const _BTIP_FOOTBALL = 1;

Future<void> main() async {
  print('🔄 Nesine Sync başlıyor...');

  if (_sbUrl.isEmpty || _sbKey.isEmpty) {
    print('❌ SUPABASE env eksik'); exit(1);
  }

  // 1. Nesine'den futbol maçları
  print('📡 GetLiveBetResults...');
  final nRes = await http.post(
    Uri.parse('https://www.nesine.com/LiveScore/GetLiveBetResults'),
    headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/122.0.0.0',
      'Accept': 'application/json',
      'X-Requested-With': 'XMLHttpRequest',
      'Referer': 'https://www.nesine.com/iddaa/canli-iddaa-canli-bahis',
    },
  ).timeout(const Duration(seconds: 20));

  if (nRes.statusCode != 200) {
    print('❌ Nesine HTTP ${nRes.statusCode}'); exit(1);
  }

  final nList = (jsonDecode(nRes.body) as List)
      .where((m) => m is Map &&
          (m['BTIP'] == _BTIP_FOOTBALL || m['SportType'] == _BTIP_FOOTBALL))
      .cast<Map>().toList();
  print('   ${nList.length} futbol maçı bulundu');

  // 2. Supabase'den canlı maçlar
  print('📡 Supabase live_matches...');
  final sRes = await http.get(
    Uri.parse('$_sbUrl/rest/v1/live_matches'
        '?select=fixture_id,home_team,away_team'
        '&status_short=in.(1H,2H,HT,ET,BT,P,LIVE,NS)'),
    headers: _sbHeaders(),
  ).timeout(const Duration(seconds: 15));

  if (sRes.statusCode != 200) {
    print('❌ Supabase HTTP ${sRes.statusCode}'); exit(1);
  }

  final sbList = (jsonDecode(sRes.body) as List).cast<Map>();
  print('   ${sbList.length} maç Supabase\'de');

  // 3. Eşleştir → nesine_bid yaz
  int matched = 0, skipped = 0;
  for (final nm in nList) {
    final bid   = _int(nm['BID']);
    final nHome = (nm['HomeTeam'] ?? '').toString();
    final nAway = (nm['AwayTeam'] ?? '').toString();
    if (bid == null || nHome.isEmpty) continue;

    Map? best; double bestScore = 0;
    for (final sb in sbList) {
      final s = (_sim(nHome, (sb['home_team'] ?? '').toString()) +
                 _sim(nAway, (sb['away_team'] ?? '').toString())) / 2;
      if (s > bestScore && s >= 0.45) { bestScore = s; best = sb; }
    }

    if (best == null || bestScore < 0.45) {
      print('⚠️ Eşleşme yok: $nHome vs $nAway (best: ${bestScore.toStringAsFixed(2)})');
      skipped++; continue;
    }

    final fid = best['fixture_id'] as int;
    print('🔗 bid=$bid ↔ fixture=$fid (${bestScore.toStringAsFixed(2)}) $nHome vs $nAway');

    // Supabase'e nesine_bid yaz
    final pRes = await http.patch(
      Uri.parse('$_sbUrl/rest/v1/live_matches?fixture_id=eq.$fid'),
      headers: {..._sbHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode({'nesine_bid': bid}),
    ).timeout(const Duration(seconds: 8));

    if (pRes.statusCode < 300) matched++;
    else print('   ❌ Yazma hatası: ${pRes.statusCode}');
  }

  print('\n✅ Tamamlandı: $matched eşleşti, $skipped atlandı');
  exit(0);
}

Map<String, String> _sbHeaders() => {
  'apikey': _sbKey, 'Authorization': 'Bearer $_sbKey',
  'Prefer': 'return=minimal',
};

int? _int(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  return int.tryParse(v.toString());
}

double _sim(String a, String b) {
  final n1 = _norm(a), n2 = _norm(b);
  if (n1 == n2) return 1.0;
  if (n1.contains(n2) || n2.contains(n1)) return 0.9;
  final w1 = n1.split(' ').where((t) => t.length > 1).toSet();
  final w2 = n2.split(' ').where((t) => t.length > 1).toSet();
  if (w1.isEmpty || w2.isEmpty) return 0.0;
  final j = w1.intersection(w2).length / w1.union(w2).length;
  if (j >= 0.5) return 0.7 + j * 0.2;
  if (n1.length >= 3 && n2.length >= 3 && n1.substring(0,3) == n2.substring(0,3)) return 0.6;
  return j * 0.5;
}

String _norm(String s) => s.toLowerCase()
    .replaceAll('ı','i').replaceAll('ğ','g').replaceAll('ü','u')
    .replaceAll('ş','s').replaceAll('ö','o').replaceAll('ç','c')
    .replaceAll('é','e').replaceAll('á','a').replaceAll('ñ','n')
    .replaceAll(RegExp(r'[^\w\s]'), '')
    .replaceAll(RegExp(r'\s+'), ' ').trim();
