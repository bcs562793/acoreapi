// ================================================================
// Nesine WebSocket Live Score Listener
// GetLiveBetResults → BID eşleştir → LiveBets_V3 dinle → Supabase yaz
//
// ENV:
//   SUPABASE_URL
//   SUPABASE_KEY
// ================================================================

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

const _nesineHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/122.0.0.0',
  'Accept': 'application/json, text/javascript, */*; q=0.01',
  'Accept-Language': 'tr-TR,tr;q=0.9',
  'Referer': 'https://www.nesine.com/iddaa/canli-iddaa-canli-bahis',
  'X-Requested-With': 'XMLHttpRequest',
  'Origin': 'https://www.nesine.com',
};

// MT=11 → Gol/Skor güncellemesi
const _MT_SCORE = 11;

// BTIP=1 → Futbol
const _BTIP_FOOTBALL = 1;

// Status → canlı maç statüleri
const _liveStatuses = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};

// ── STATE ─────────────────────────────────────────────────────
// nesine_bid → _Match
final Map<int, _Match> _tracked = {};
WebSocketChannel? _ws;
Timer? _pingTimer;
int _goalCount = 0, _writeCount = 0;

// ── MAIN ──────────────────────────────────────────────────────
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
      ..write(jsonEncode({'ok': true, 'tracked': _tracked.length,
          'goals': _goalCount, 'writes': _writeCount}))
      ..close());
    print('🌐 Health: :$port');
  });

  // İlk eşleştirme
  await _syncMatches();

  // Her 30sn eşleştirmeyi yenile
  Timer.periodic(const Duration(seconds: 30), (_) => _syncMatches());

  // Her 5dk istatistik
  Timer.periodic(const Duration(minutes: 5), (_) =>
    print('📊 Takip:${_tracked.length} Gol:$_goalCount Yaz:$_writeCount'));

  // WS döngüsü
  while (true) {
    try { await _connect(); } catch (e) { print('❌ WS: $e'); }
    print('🔄 10sn sonra yeniden bağlanıyor...');
    await Future.delayed(const Duration(seconds: 10));
  }
}

// ── ADIM 1: Nesine maç listesi → Supabase eşleştir ────────────
Future<void> _syncMatches() async {
  try {
    // 1a. Nesine'den futbol maçlarını çek
    final res = await http.post(
      Uri.parse('https://www.nesine.com/LiveScore/GetLiveBetResults'),
      headers: _nesineHeaders,
    ).timeout(const Duration(seconds: 10));

    if (res.statusCode != 200) return;

    final list = jsonDecode(res.body) as List;
    // Sadece futbol (BTIP=1)
    final football = list.where((m) =>
      m is Map && (m['BTIP'] == _BTIP_FOOTBALL || m['SportType'] == _BTIP_FOOTBALL)
    ).cast<Map>().toList();

    if (football.isEmpty) return;

    // 1b. Supabase'den canlı maçları çek
    final sbRes = await http.get(
      Uri.parse('$_sbUrl/rest/v1/live_matches'
          '?select=fixture_id,home_team,away_team,home_score,away_score,status_short'
          '&status_short=in.(1H,2H,HT,ET,BT,P,LIVE,NS)'),
      headers: _sbHeaders(),
    ).timeout(const Duration(seconds: 10));

    if (sbRes.statusCode != 200) return;
    final sbMatches = (jsonDecode(sbRes.body) as List).cast<Map>();

    // 1c. İsim benzerliği ile eşleştir
    final liveIds = <int>{};
    for (final nm in football) {
      final bid      = _int(nm['BID']);
      final nHome    = (nm['HomeTeam'] ?? '').toString();
      final nAway    = (nm['AwayTeam'] ?? '').toString();
      if (bid == null || nHome.isEmpty) continue;

      liveIds.add(bid);

      // Zaten takipteyse score güncelle
      if (_tracked.containsKey(bid)) continue;

      // Supabase'de eşleşen maç ara
      Map? best;
      double bestScore = 0;
      for (final sb in sbMatches) {
        final sbHome = (sb['home_team'] ?? '').toString();
        final sbAway = (sb['away_team'] ?? '').toString();
        final s = (_sim(nHome, sbHome) + _sim(nAway, sbAway)) / 2;
        if (s > bestScore && s >= 0.55) {
          bestScore = s; best = sb;
        }
      }

      if (best != null) {
        final fid = best['fixture_id'] as int;
        _tracked[bid] = _Match(
          fixtureId: fid,
          nesineBid: bid,
          homeTeam:  (best['home_team'] ?? '').toString(),
          awayTeam:  (best['away_team'] ?? '').toString(),
          homeScore: _int(best['home_score']) ?? 0,
          awayScore: _int(best['away_score']) ?? 0,
        );
        print('🔗 bid=$bid ↔ fixture=$fid '
              '(${bestScore.toStringAsFixed(2)}) $nHome vs $nAway');

        // nesine_bid kolonunu Supabase'e kaydet
        _sbPatch(fid, {'nesine_bid': bid, 'score_source': 'nesine'});
      }
    }

    // Artık canlı olmayan maçları çıkar
    _tracked.removeWhere((bid, m) {
      if (!liveIds.contains(bid)) {
        print('➖ bid=$bid takipten çıktı');
        return true;
      }
      return false;
    });

  } catch (e) {
    print('⚠️ syncMatches: $e');
  }
}

// ── ADIM 2: WebSocket bağlantısı ──────────────────────────────
Future<void> _connect() async {
  print('🔌 rt.nesine.com bağlanıyor...');
  _ws = IOWebSocketChannel.connect(Uri.parse(_wsUrl), headers: {
    'Origin': 'https://www.nesine.com',
    'User-Agent': 'Mozilla/5.0 Chrome/122.0.0.0',
  });

  _pingTimer?.cancel();
  _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
    try { _ws?.sink.add('2'); } catch (_) {}
  });

  try {
    await for (final raw in _ws!.stream) {
      _onRaw(raw.toString());
    }
  } catch (e) {
    print('[ERR] WS stream: $e');
  }
  final code   = _ws?.closeCode;
  final reason = _ws?.closeReason;
  _pingTimer?.cancel();
  _ws = null;
  print('[WS] Kapandi closeCode=$code reason=$reason');
}

void _onRaw(String s) {
  if (s == '2') { _ws?.sink.add('3'); return; }
  if (s == '3') return;
  if (s.startsWith('0')) {
    try {
      jsonDecode(s.substring(1)); // handshake parse
      _ws?.sink.add('40');
    } catch (_) {}
    return;
  }
  if (s.startsWith('40')) {
    print('✅ WS bağlandı → joinroom LiveBets_V3');
    _ws?.sink.add('42["joinroom","LiveBets_V3"]');
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
      // Sadece futbol
      if ((item['sportype'] ?? '').toString().toLowerCase() != 'football') continue;
      final m   = item['M'] as Map?;
      if (m == null) continue;
      final bid = _int(m['BID'] ?? item['bid']);
      if (bid == null) return;
      _onScore(bid, m);
    }
  } catch (_) {}
}

// ── ADIM 3: Skor geldi → Supabase yaz ─────────────────────────
void _onScore(int bid, Map m) {
  final match = _tracked[bid];
  if (match == null) return;

  final newH = _int(m['H']);
  final newA = _int(m['A']);
  final min  = _int(m['T']);
  if (newH == null || newA == null) return;
  if (newH == match.homeScore && newA == match.awayScore) return;

  _goalCount++;
  print('⚽ GOL! bid=$bid ${match.homeTeam} '
      '${match.homeScore}-${match.awayScore} → $newH-$newA'
      '${min != null ? " ($min\')" : ""}');

  match.homeScore = newH;
  match.awayScore = newA;

  _sbPatch(match.fixtureId, {
    'home_score':   newH,
    'away_score':   newA,
    'score_source': 'nesine',
    if (min != null) 'elapsed_time': min,
    'updated_at': DateTime.now().toIso8601String(),
  });
}

// ── SUPABASE ──────────────────────────────────────────────────
Future<void> _sbPatch(int fid, Map<String, dynamic> data) async {
  try {
    final res = await http.patch(
      Uri.parse('$_sbUrl/rest/v1/live_matches?fixture_id=eq.$fid'),
      headers: {..._sbHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(data),
    ).timeout(const Duration(seconds: 8));
    if (res.statusCode < 300) _writeCount++;
    else print('❌ SB $fid: ${res.statusCode}');
  } catch (e) { print('❌ SB patch: $e'); }
}

Map<String, String> _sbHeaders() => {
  'apikey': _sbKey, 'Authorization': 'Bearer $_sbKey',
  'Prefer': 'return=minimal',
};

// ── YARDIMCI ──────────────────────────────────────────────────
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

// ── MODEL ─────────────────────────────────────────────────────
class _Match {
  final int fixtureId, nesineBid;
  final String homeTeam, awayTeam;
  int homeScore, awayScore;
  _Match({required this.fixtureId, required this.nesineBid,
      required this.homeTeam, required this.awayTeam,
      required this.homeScore, required this.awayScore});
}
