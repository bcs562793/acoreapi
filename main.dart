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


// nesine_bid → _SbMatch
final Map<int, _SbMatch> _matches = {};

WebSocketChannel? _ws;
Timer? _pingTimer;
int _goalCount = 0, _writeCount = 0;

Future<void> main() async {
  print('╔══════════════════════════════════════╗');
  print('║  ⚡ Nesine Score Listener            ║');
  print('╚══════════════════════════════════════╝');

  if (_sbUrl.isEmpty || _sbKey.isEmpty) {
    print('❌ SUPABASE env eksik'); exit(1);
  }

  final port = int.tryParse(Platform.environment['PORT'] ?? '8082') ?? 8082;
  HttpServer.bind('0.0.0.0', port).then((s) {
    s.listen((req) => req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'ok': true, 'matches': _matches.length,
          'goals': _goalCount, 'writes': _writeCount}))
      ..close());
    print('🌐 Health: :$port');
  });

  // Supabase'den nesine_bid'li maçları yükle
  await _loadMatches();
  Timer.periodic(const Duration(minutes: 5), (_) => _loadMatches());
  Timer.periodic(const Duration(minutes: 5), (_) =>
    print('📊 Maç:${_matches.length} Gol:$_goalCount Yaz:$_writeCount'));

  // WS döngüsü
  while (true) {
    try { await _connect(); } catch (e) { print('❌ WS: $e'); }
    await Future.delayed(const Duration(seconds: 3));
  }
}

// Supabase'den nesine_bid dolu maçları çek
Future<void> _loadMatches() async {
  try {
    final res = await http.get(
      Uri.parse('$_sbUrl/rest/v1/live_matches'
          '?select=fixture_id,home_team,away_team,home_score,away_score,nesine_bid'
          '&status_short=in.(1H,2H,HT,ET,BT,P,LIVE,NS)'
          '&nesine_bid=not.is.null'),
      headers: _sbHeaders(),
    ).timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) return;
    final rows = (jsonDecode(res.body) as List).cast<Map>();

    _matches.clear();
    for (final r in rows) {
      final bid = _int(r['nesine_bid']);
      if (bid == null) continue;
      _matches[bid] = _SbMatch(
        fixtureId: r['fixture_id'] as int,
        homeTeam:  (r['home_team'] ?? '').toString(),
        awayTeam:  (r['away_team'] ?? '').toString(),
        homeScore: _int(r['home_score']) ?? 0,
        awayScore: _int(r['away_score']) ?? 0,
      );
    }
    print('📋 ${_matches.length} maç yüklendi (nesine_bid doldu)');
    for (final e in _matches.entries) {
      print('   bid=${e.key} → ${e.value.homeTeam} vs ${e.value.awayTeam}');
    }
  } catch (e) {
    print('⚠️ loadMatches: $e');
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
      // Sadece Football
      if ((item['sportype'] ?? '').toString().toLowerCase() != 'football') continue;
      final m = item['M'] as Map?;
      if (m == null) continue;
      final bid = _int(m['BID'] ?? item['bid']);
      if (bid == null) continue;

      // H ve A sayısal ve makul bir futbol skoru ise işle
      final h = _int(m['H']);
      final a = _int(m['A']);
      if (h == null || a == null) continue;   // sayı değilse atla
      if (h > 30 || a > 30) continue;         // 30+ istatistik
      if (m.containsKey('EN')) continue;      // EN=istatistik adı varsa atla
      if (!m.containsKey('TS')) continue;     // TS yoksa skor event'i değil
      if (m['ST'] != 1) continue;             // ST=1 aktif skor

      _onScore(bid, m);
    }
  } catch (_) {}
}

void _onScore(int bid, Map m) {
  final match = _matches[bid];
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

  _sbPatch(match.fixtureId, {
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

class _SbMatch {
  final int fixtureId;
  final String homeTeam, awayTeam;
  int homeScore, awayScore;
  _SbMatch({required this.fixtureId, required this.homeTeam,
      required this.awayTeam, required this.homeScore, required this.awayScore});
}
