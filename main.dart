import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _sbUrl = Platform.environment['SUPABASE_URL'] ?? '';
final _sbKey = Platform.environment['SUPABASE_KEY'] ?? '';

const _wsUrl = 'wss://rt.nesine.com/socket.io/'
    '?platformid=1'
    '&userAgent=Mozilla%2F5.0%20(Windows%20NT%2010.0%3B%20Win64%3B%20x64)%20'
    'AppleWebKit%2F537.36%20(KHTML%2C%20like%20Gecko)%20'
    'Chrome%2F122.0.0.0%20Safari%2F537.36'
    '&EIO=4&transport=websocket';

const _MT_SCORE = 11;
const _BTIP_FOOTBALL = 1;

// bid → fixture_id
final Map<int, int> _bidToFixture = {};
// fixture_id → _SbMatch
final Map<int, _SbMatch> _sbMatches = {};

WebSocketChannel? _ws;
Timer? _pingTimer;
int _goalCount = 0, _writeCount = 0;

Future<void> main() async {
  print('╔══════════════════════════════════════╗');
  print('║  ⚡ Nesine Score Listener            ║');
  print('╚══════════════════════════════════════╝');

  if (_sbUrl.isEmpty || _sbKey.isEmpty) {
    print('❌ SUPABASE_URL / SUPABASE_KEY eksik'); exit(1);
  }

  final port = int.tryParse(Platform.environment['PORT'] ?? '8082') ?? 8082;
  HttpServer.bind('0.0.0.0', port).then((s) {
    s.listen((req) => req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'ok': true,
          'sb': _sbMatches.length,
          'bids': _bidToFixture.length,
          'goals': _goalCount,
          'writes': _writeCount}))
      ..close());
    print('🌐 Health: :$port');
  });

  // Nesine maç listesi → bid eşleştir
  await _syncNesine();
  Timer.periodic(const Duration(minutes: 10), (_) => _syncNesine());
  Timer.periodic(const Duration(minutes: 5), (_) =>
    print('📊 SB:${_sbMatches.length} BID:${_bidToFixture.length} Gol:$_goalCount Yaz:$_writeCount'));

  // WS döngüsü — kapanınca hemen yeniden bağlan
  while (true) {
    try { await _connect(); } catch (e) { print('❌ WS: $e'); }
    print('🔄 3sn sonra yeniden bağlanılacak...');
    await Future.delayed(const Duration(seconds: 3));
  }
}

// Nesine maç listesi + Supabase eşleştirme
Future<void> _syncNesine() async {
  try {
    // 1. Nesine'den futbol maçları
    final nRes = await http.post(
      Uri.parse('https://www.nesine.com/LiveScore/GetLiveBetResults'),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/122.0.0.0',
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': 'https://www.nesine.com/iddaa/canli-iddaa-canli-bahis',
      },
    ).timeout(const Duration(seconds: 20));
    if (nRes.statusCode != 200) return;

    final nList = (jsonDecode(nRes.body) as List)
        .where((m) => m is Map &&
            (m['BTIP'] == _BTIP_FOOTBALL || m['SportType'] == _BTIP_FOOTBALL))
        .cast<Map>().toList();

    // 2. Supabase'den canlı maçlar
    final sRes = await http.get(
      Uri.parse('$_sbUrl/rest/v1/live_matches'
          '?select=fixture_id,home_team,away_team,home_score,away_score'
          '&status_short=in.(1H,2H,HT,ET,BT,P,LIVE,NS)'),
      headers: _sbHeaders(),
    ).timeout(const Duration(seconds: 15));
    if (sRes.statusCode != 200) return;

    final sbList = (jsonDecode(sRes.body) as List).cast<Map>();

    _sbMatches.clear();
    for (final r in sbList) {
      final fid = r['fixture_id'] as int;
      _sbMatches[fid] = _SbMatch(
        fixtureId: fid,
        homeTeam: (r['home_team'] ?? '').toString(),
        awayTeam: (r['away_team'] ?? '').toString(),
        homeScore: _int(r['home_score']) ?? 0,
        awayScore: _int(r['away_score']) ?? 0,
      );
    }

    // 3. İsim benzerliği ile eşleştir
    int matched = 0;
    for (final nm in nList) {
      final bid   = _int(nm['BID']);
      final nHome = (nm['HomeTeam'] ?? '').toString();
      final nAway = (nm['AwayTeam'] ?? '').toString();
      if (bid == null || nHome.isEmpty) continue;
      if (_bidToFixture.containsKey(bid)) continue;

      Map? best; double bestScore = 0;
      for (final sb in _sbMatches.values) {
        final s = (_sim(nHome, sb.homeTeam) + _sim(nAway, sb.awayTeam)) / 2;
        if (s > bestScore && s >= 0.55) { bestScore = s; best = {'fid': sb.fixtureId, 'h': sb.homeTeam, 'a': sb.awayTeam}; }
      }
      if (best != null) {
        _bidToFixture[bid] = best['fid'] as int;
        print('🔗 bid=$bid ↔ fixture=${best['fid']} (${bestScore.toStringAsFixed(2)}) $nHome vs $nAway');
        matched++;
      }
    }
    print('📋 SB:${_sbMatches.length} Nesine:${nList.length} Yeni eşleşme:$matched');
  } catch (e) {
    print('⚠️ syncNesine: $e');
  }
}

Future<void> _connect() async {
  print('🔌 Bağlanıyor...');
  _ws = IOWebSocketChannel.connect(Uri.parse(_wsUrl), headers: {
    'Origin':        'https://www.nesine.com',
    'User-Agent':    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/122.0.0.0',
    'Cache-Control': 'no-cache',
  });
  _pingTimer?.cancel();
  try {
    await for (final raw in _ws!.stream) { _onRaw(raw.toString()); }
  } catch (e) { print('[ERR] $e'); }
  final code = _ws?.closeCode;
  _pingTimer?.cancel();
  _ws = null;
  print('[WS] Kapandı code=$code');
}

void _onRaw(String s) {
  if (s == '2') { _ws?.sink.add('3'); return; }
  if (s == '3') return;
  if (s.startsWith('0')) {
    try { _ws?.sink.add('40'); } catch (_) {}
    return;
  }
  if (s.startsWith('40')) {
    print('✅ WS bağlandı');
    _ws?.sink.add('42["joinroom","LiveBets_V3"]');
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      try { _ws?.sink.add('2'); } catch (_) {}
    });
    return;
  }
  if (s.startsWith('42')) _onEvent(s.substring(2));
}

void _onEvent(String payload) {
  try {
    final list = jsonDecode(payload) as List;
    if (list[0] != 'LiveBets' || list[1] is! List) return;
    for (final item in list[1] as List) {
      if (item is! Map) continue;
      if (item['MT'] != _MT_SCORE) continue;
      if ((item['sportype'] ?? '').toString().toLowerCase() != 'football') continue;
      final m = item['M'] as Map?;
      if (m == null) continue;
      final bid = _int(m['BID'] ?? item['bid']);
      if (bid == null) continue;
      _onScore(bid, m);
    }
  } catch (_) {}
}

void _onScore(int bid, Map m) {
  final fid = _bidToFixture[bid];
  if (fid == null) return;

  final sb = _sbMatches[fid];
  if (sb == null) return;

  final newH = _int(m['H']);
  final newA = _int(m['A']);
  final min  = _int(m['T']);
  if (newH == null || newA == null) return;
  if (newH == sb.homeScore && newA == sb.awayScore) return;

  _goalCount++;
  print('⚽ GOL! bid=$bid ${sb.homeTeam} ${sb.homeScore}-${sb.awayScore} → $newH-$newA'
      '${min != null ? " ($min\')" : ""}');

  sb.homeScore = newH;
  sb.awayScore = newA;

  _sbPatch(fid, {
    'home_score': newH, 'away_score': newA,
    'score_source': 'nesine',
    if (min != null) 'elapsed_time': min,
    'updated_at': DateTime.now().toIso8601String(),
  });
}

Future<void> _sbPatch(int fid, Map<String, dynamic> data) async {
  try {
    final res = await http.patch(
      Uri.parse('$_sbUrl/rest/v1/live_matches?fixture_id=eq.$fid'),
      headers: {..._sbHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(data),
    ).timeout(const Duration(seconds: 8));
    if (res.statusCode < 300) _writeCount++;
    else print('❌ SB $fid: ${res.statusCode}');
  } catch (e) { print('❌ SB: $e'); }
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

class _SbMatch {
  final int fixtureId;
  final String homeTeam, awayTeam;
  int homeScore, awayScore;
  _SbMatch({required this.fixtureId, required this.homeTeam,
      required this.awayTeam, required this.homeScore, required this.awayScore});
}
