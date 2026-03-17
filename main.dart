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

// fixture_id → _Match  (Supabase'den yüklenir)
final Map<int, _Match> _byFixture = {};
// nesine_bid → fixture_id  (WS'den öğrenilir)
final Map<int, int> _bidToFixture = {};

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

  // Health check
  final port = int.tryParse(Platform.environment['PORT'] ?? '8082') ?? 8082;
  HttpServer.bind('0.0.0.0', port).then((s) {
    s.listen((req) => req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'ok': true,
          'fixtures': _byFixture.length,
          'bids': _bidToFixture.length,
          'goals': _goalCount,
          'writes': _writeCount}))
      ..close());
    print('🌐 Health: :$port');
  });

  // Sadece Supabase'den maç listesini çek — Nesine'ye HTTP yok
  await _loadFixtures();
  Timer.periodic(const Duration(minutes: 5), (_) => _loadFixtures());

  Timer.periodic(const Duration(minutes: 5), (_) =>
    print('📊 Maç:${_byFixture.length} BID:${_bidToFixture.length} Gol:$_goalCount Yaz:$_writeCount'));

  // WS döngüsü
  while (true) {
    try { await _connect(); } catch (e) { print('❌ WS: $e'); }
    print('🔄 30sn sonra yeniden bağlanılacak...');
    await Future.delayed(const Duration(seconds: 30));
  }
}

// Sadece Supabase'den fixture listesi — Nesine'ye tek HTTP bile yok
Future<void> _loadFixtures() async {
  try {
    final res = await http.get(
      Uri.parse('$_sbUrl/rest/v1/live_matches'
          '?select=fixture_id,home_team,away_team,home_score,away_score'
          '&status_short=in.(1H,2H,HT,ET,BT,P,LIVE,NS)'),
      headers: _sbHeaders(),
    ).timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) return;
    final rows = (jsonDecode(res.body) as List).cast<Map>();

    _byFixture.clear();
    for (final r in rows) {
      final fid = r['fixture_id'] as int;
      _byFixture[fid] = _Match(
        fixtureId: fid,
        homeTeam:  (r['home_team'] ?? '').toString(),
        awayTeam:  (r['away_team'] ?? '').toString(),
        homeScore: _int(r['home_score']) ?? 0,
        awayScore: _int(r['away_score']) ?? 0,
      );
    }
    print('📋 ${_byFixture.length} maç Supabase\'den yüklendi');
  } catch (e) {
    print('⚠️ loadFixtures: $e');
  }
}

Future<void> _connect() async {
  print('🔌 rt.nesine.com bağlanıyor...');
  _ws = IOWebSocketChannel.connect(Uri.parse(_wsUrl), headers: {
    'Origin':        'https://www.nesine.com',
    'User-Agent':    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/122.0.0.0',
    'Cache-Control': 'no-cache',
  });

  _pingTimer?.cancel();

  try {
    await for (final raw in _ws!.stream) {
      _onRaw(raw.toString());
    }
  } catch (e) {
    print('[ERR] WS: $e');
  }

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

      // BID → fixture_id eşleştirmesi daha önce yapıldıysa direkt kullan
      // Yoksa tüm maçlarla isim benzerliği dene — WS'deki NID üzerinden
      _onScore(bid, m);
    }
  } catch (_) {}
}

void _onScore(int bid, Map m) {
  // Önce cache'e bak
  int? fid = _bidToFixture[bid];

  // Cache'de yoksa — WS'deki NevId/NID ile eşleştirmeyi daha sonra ekleyebiliriz
  // Şimdilik: daha önce nesine_bid kaydedilmiş maçları bul
  if (fid == null) return;

  final match = _byFixture[fid];
  if (match == null) return;

  final newH = _int(m['H']);
  final newA = _int(m['A']);
  final min  = _int(m['T']);
  if (newH == null || newA == null) return;
  if (newH == match.homeScore && newA == match.awayScore) return;

  _goalCount++;
  print('⚽ GOL! bid=$bid ${match.homeTeam} ${match.homeScore}-${match.awayScore} → $newH-$newA'
      '${min != null ? " ($min\')" : ""}');

  match.homeScore = newH;
  match.awayScore = newA;

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

class _Match {
  final int fixtureId;
  final String homeTeam, awayTeam;
  int homeScore, awayScore;
  _Match({required this.fixtureId,
      required this.homeTeam, required this.awayTeam,
      required this.homeScore, required this.awayScore});
}
