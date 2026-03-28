import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _sbUrl = Platform.environment['SUPABASE_URL'] ?? '';
final _sbKey = Platform.environment['SUPABASE_KEY'] ?? '';

const _nesineWsUrl = 'wss://rt.nesine.com/socket.io/'
    '?platformid=1'
    '&userAgent=Mozilla%2F5.0%20(Windows%20NT%2010.0%3B%20Win64%3B%20x64)%20'
    'AppleWebKit%2F537.36%20(KHTML%2C%20like%20Gecko)%20'
    'Chrome%2F122.0.0.0%20Safari%2F537.36'
    '&EIO=4&transport=websocket';

const _bilyonerWsUrl = 'wss://apiwsw.bilyoner.com/ws/connect';

const _bilyonerBase           = 'https://www.bilyoner.com';
const _bilyonerPlatformToken  = '40CAB7292CD83F7EE0631FC35A0AFC75';
const _bilyonerDeviceId       = 'C1A34687-8F75-47E8-9FF9-1D231F05782E';
const _bilyonerAppVersion     = '3.95.2';
const _bilyonerChromeVersion  = '146';
const _bilyonerBrowserVersion = 'Chrome / v146.0.0.0';

const Map<int, String> _nesineStMap = {
  1: '1H', 2: 'HT', 3: '2H', 4: 'ET', 5: 'BT',
  6: 'P',  7: 'FT', 8: 'AET', 9: 'PEN', 10: 'PST', 11: 'CANC',
};

const Map<String, String> _nesineStStrMap = {
  'MS': '1H', 'HT': 'HT', 'SH': '2H', 'MS2': '2H',
  'FT': 'FT', 'ET': 'ET', 'PEN': 'PEN', 'PST': 'PST', 'CANC': 'CANC',
};

const Map<String, String> _bilyonerPeriodMap = {
  'FIRST_HALF': '1H', 'HALF_TIME': 'HT', 'SECOND_HALF': '2H',
  'EXTRA_TIME': 'ET', 'EXTRA_TIME_FIRST_HALF': 'ET',
  'EXTRA_TIME_HALF_TIME': 'BT', 'EXTRA_TIME_SECOND_HALF': 'ET',
  'PENALTY': 'P', 'PENALTIES': 'P',
  'FULL_TIME': 'FT',
  'FINISHED': 'FT', 'ENDED': 'FT',
  'POST_GAME': 'FT',
  'AFTER_EXTRA_TIME': 'AET', 'AFTER_PENALTIES': 'PEN',
  'POSTPONED': 'PST', 'CANCELLED': 'CANC', 'NOT_STARTED': 'NS',
};

const Map<String, String> _statusLong = {
  '1H': '1. Yarı', 'HT': 'D.A.',   '2H': '2. Yarı',
  'ET': 'Uzatma',  'BT': 'Uzatma D.A.', 'P': 'Penaltılar',
  'FT': 'MS', 'AET': 'MS (UZ)', 'PEN': 'MS (PEN)',
  'PST': 'Ertelendi', 'CANC': 'İptal', 'NS': 'Başlamadı',
};

const _basketballPeriods = {
  'FIRST_QUARTER','SECOND_QUARTER','THIRD_QUARTER','FOURTH_QUARTER',
  'QUARTER','OVERTIME',
};

class _LiveMatch {
  final int    fixtureId;
  final String homeTeam, awayTeam;
  int          homeScore, awayScore;
  String       statusShort;
  String       rawData;
  int?         nesineBid;
  int?         kickoffTs;

  _LiveMatch({
    required this.fixtureId, required this.homeTeam, required this.awayTeam,
    required this.homeScore, required this.awayScore,
    required this.statusShort, required this.rawData,
    this.nesineBid, this.kickoffTs,
  });
}

final Map<int, _LiveMatch> _fixtures      = {};
final Set<int>             _addingFids    = {};
final Map<int, int>        _bidToFid      = {};
final Set<int>             _nesineGuarded = {};

// ── Elapsed cache: aynı dakikayı 30s içinde tekrar yazma ─────────
final Map<int, DateTime> _lastWrite          = {};
final Map<int, int>      _lastElapsedWritten = {};

// ── HTTP elapsed rate-limit: aynı fid için 25s'de bir çek ────────
final Map<int, DateTime> _lastElapsedFetch = {};

int _nesineGoals = 0, _bilyonerUpdates = 0, _writeCount = 0;

// ══════════════════════════════════════════════════════════════════
// BİLYONER HTTP — elapsed (dakika) çekme
// ══════════════════════════════════════════════════════════════════
Map<String, String> _bilyonerHttpHeaders() => {
  'accept':                   'application/json, text/plain, */*',
  'accept-language':          'tr',
  'accept-encoding':          'gzip, deflate, br, zstd',
  'cache-control':            'no-cache',
  'pragma':                   'no-cache',
  'referer':                  '$_bilyonerBase/canli-iddaa',
  'sec-ch-ua':                '"Chromium";v="$_bilyonerChromeVersion", "Not-A.Brand";v="24", "Google Chrome";v="$_bilyonerChromeVersion"',
  'sec-ch-ua-mobile':         '?0',
  'sec-ch-ua-platform':       '"macOS"',
  'sec-fetch-dest':           'empty',
  'sec-fetch-mode':           'cors',
  'sec-fetch-site':           'same-origin',
  'user-agent':               'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$_bilyonerChromeVersion.0.0.0 Safari/537.36',
  'platform-token':           _bilyonerPlatformToken,
  'x-client-app-version':     _bilyonerAppVersion,
  'x-client-browser-version': _bilyonerBrowserVersion,
  'x-client-channel':         'WEB',
  'x-device-id':              _bilyonerDeviceId,
};

/// Bilyoner live-score HTTP endpoint'inden dakika bilgisini çek.
/// currentScore.time → "33'" → 33, "45+2'" → 45
/// Rate-limit: aynı fid için 25 saniyede bir.
Future<int?> _fetchElapsed(int fid, String status) async {
  // HT, BT, P için sabit değer — HTTP'ye gitme
  if (status == 'HT') return 45;
  if (status == 'BT') return 105;
  if (status == 'P')  return 120;

  // Rate-limit kontrolü
  final lastFetch = _lastElapsedFetch[fid];
  if (lastFetch != null &&
      DateTime.now().difference(lastFetch).inSeconds < 25) {
    return null; // throttle — mevcut değeri koru
  }
  _lastElapsedFetch[fid] = DateTime.now();

  try {
    final uri = Uri.parse(
      '$_bilyonerBase/api/mobile/live-score/event/v2/sport-list'
      '?eventList=1:$fid',
    );
    final res = await http
        .get(uri, headers: _bilyonerHttpHeaders())
        .timeout(const Duration(seconds: 6));

    if (res.statusCode != 200) {
      print('⚠️ elapsed HTTP [${res.statusCode}] fid=$fid');
      return null;
    }

    final body   = jsonDecode(res.body) as Map<String, dynamic>;
    final events = body['events'] as List? ?? [];
    if (events.isEmpty) return null;

    final ev = events.firstWhere(
      (e) => e is Map && _int(e['sbsEventId']) == fid,
      orElse: () => events[0],
    );
    if (ev == null) return null;

    final cs      = (ev as Map)['currentScore'] as Map? ?? {};
    final timeRaw = cs['time'] as String? ?? '';
    if (timeRaw.isEmpty || timeRaw == '-') return null;

    // "45+2'" → 45, "33'" → 33
    final cleaned = timeRaw.replaceAll("'", '').trim();
    final base    = cleaned.split('+').first.trim();
    final parsed  = int.tryParse(base);

    if (parsed != null && parsed > 0) {
      print('   ⏱  elapsed HTTP fid=$fid: "$timeRaw" → $parsed\'');
    }
    return parsed;
  } catch (e) {
    print('⚠️ _fetchElapsed ($fid): $e');
    return null;
  }
}

// ══════════════════════════════════════════════════════════════════
// MAIN
// ══════════════════════════════════════════════════════════════════
Future<void> main() async {
  print('╔══════════════════════════════════════╗');
  print('║  ⚡ Score Listener v9                ║');
  print('║  📡 Nesine WS (skor)                 ║');
  print('║  📡 Bilyoner WS (status+skor)        ║');
  print('║  📡 Bilyoner HTTP (elapsed/dakika)   ║');
  print('╚══════════════════════════════════════╝');

  if (_sbUrl.isEmpty || _sbKey.isEmpty) { print('❌ SUPABASE env eksik'); exit(1); }

  final port = int.tryParse(Platform.environment['PORT'] ?? '8082') ?? 8082;
  HttpServer.bind('0.0.0.0', port).then((s) {
    s.listen((req) => req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({
        'ok': true, 'v': 9,
        'fixtures': _fixtures.length,
        'nesine_mapped': _bidToFid.length,
        'nesine_guarded': _nesineGuarded.length,
        'nesine_goals': _nesineGoals,
        'bilyoner_updates': _bilyonerUpdates,
        'writes': _writeCount,
      }))
      ..close());
    print('🌐 Health: :$port');
  });

  await _loadFixtures();
  Timer.periodic(const Duration(minutes: 3), (_) => _loadFixtures());
  Timer.periodic(const Duration(minutes: 3), (_) => _cleanStaleMatches());
  Timer.periodic(const Duration(minutes: 5), (_) =>
      print('📊 Maç:${_fixtures.length} NesEşl:${_bidToFid.length}'
            ' Gol:$_nesineGoals Bly:$_bilyonerUpdates Yaz:$_writeCount'));

  unawaited(_nesineLoop('A'));
  await Future.delayed(const Duration(seconds: 10));
  unawaited(_nesineLoop('B'));

  unawaited(_bilyonerLoop('C'));
  await Future.delayed(const Duration(seconds: 10));
  unawaited(_bilyonerLoop('D'));

  await Completer<void>().future;
}

// ══════════════════════════════════════════════════════════════════
// BİLYONER WS
// ══════════════════════════════════════════════════════════════════
Future<void> _bilyonerLoop(String name) async {
  while (true) {
    try { await _bilyonerConnect(name); } catch (e) { print('[$name] ❌ Bly $e'); }
    print('[$name] 🔄 Bilyoner koptu...');
    await Future.delayed(const Duration(seconds: 3));
  }
}

Future<void> _bilyonerConnect(String name) async {
  print('[$name] 🔌 Bilyoner: $_bilyonerWsUrl');
  final ws = IOWebSocketChannel.connect(
    Uri.parse(_bilyonerWsUrl),
    pingInterval: const Duration(seconds: 20),
    headers: {
      'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$_bilyonerChromeVersion.0.0.0 Safari/537.36',
      'Origin':                   'https://www.bilyoner.com',
      'Referer':                  'https://www.bilyoner.com/canli-iddaa',
      'platform-token':           _bilyonerPlatformToken,
      'x-device-id':              _bilyonerDeviceId,
      'x-client-app-version':     _bilyonerAppVersion,
      'x-client-browser-version': _bilyonerBrowserVersion,
      'x-client-channel':         'WEB',
    },
  );

  Timer? ping;
  Timer? watchdog;

  void send(Map<String, dynamic> m) { try { ws.sink.add(jsonEncode(m)); } catch (_) {} }

  void resetWatchdog() {
    watchdog?.cancel();
    watchdog = Timer(const Duration(seconds: 90), () {
      print('[$name] ⚠️ Bilyoner 90s mesaj yok, kesiliyor...');
      ws.sink.close();
    });
  }

  try {
    await for (final raw in ws.stream) {
      resetWatchdog();
      final msg  = jsonDecode(raw.toString()) as Map<String, dynamic>;
      final kind = msg['kind'] as String? ?? '';
      if (kind == 'ConnectionBegin') {
        print('[$name] ✅ Bilyoner bağlandı');
        send({'kind': 'SubscribeStreamTopic', 'topic': 'perform-match-details-socket'});
        send({'kind': 'SubscribeStreamTopic', 'topic': 'updatedMobileEventsV3'});
        ping?.cancel();
        ping = Timer.periodic(const Duration(seconds: 20), (_) =>
            send({'kind': 'Ping', 'timestamp': DateTime.now().millisecondsSinceEpoch}));
        resetWatchdog();
      } else if (kind == 'Pong') {
        // bağlantı sağlıklı
      } else if (kind == 'StreamMessage') {
        final topic = msg['topic'] as String? ?? '';
        if (topic == 'perform-match-details-socket') {
          _onBilyonerData(name, msg['value'] as Map<String, dynamic>?);
        } else if (topic == 'updatedMobileEventsV3') {
          _onBilyonerEventUpdate(name, msg['value'] as Map<String, dynamic>?);
        }
      }
    }
  } catch (e) { print('[$name] [ERR] Bly $e'); }
  ping?.cancel();
  watchdog?.cancel();
  print('[$name] Bilyoner kapandı code=${ws.closeCode}');
}

// ── updatedMobileEventsV3: yeni maç tespiti ──────────────────────
void _onBilyonerEventUpdate(String name, Map<String, dynamic>? v) {
  if (v == null) return;
  final event = v['event'] as Map<String, dynamic>?;
  if (event == null) return;

  final fid = _int(event['id'] ?? event['sbsEventId']);
  if (fid == null || fid == 0) return;

  final st = _int(event['st']);
  if (st != null && st != 1) return;

  if (_fixtures.containsKey(fid)) return;

  final htn = event['htn'] as String? ?? '';
  final atn = event['atn'] as String? ?? '';
  if (htn.isEmpty || atn.isEmpty) return;

  final esdl  = _int(event['esdl']) ?? 0;
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  if (esdl > 0 && esdl > nowMs + 60000) return;

  final syntheticV = {
    'sbsEventId': fid,
    'htn': htn, 'atn': atn,
    'htpi': event['htpi'], 'atpi': event['atpi'],
    'lgn': event['lgn'] ?? '',
    'competitionId': event['competitionId'] ?? event['cid'],
    'esdl': event['esdl'],
    'periodType': 'FIRST_HALF',
    'ts': {'hs': '0', 'as': '0', 'ts': '0'},
  };

  print('[$name] 📥 Yeni maç: fid=$fid $htn vs $atn');
  _addMissingFixture(fid, syntheticV);
}

// ── perform-match-details-socket: skor/durum + HTTP elapsed ──────
void _onBilyonerData(String name, Map<String, dynamic>? v) {
  if (v == null) return;
  final periodType = v['periodType'] as String? ?? '';
  if (_basketballPeriods.contains(periodType)) return;

  final fid = _int(v['sbsEventId']);
  if (fid == null || fid == 0) return;

  final fixture = _fixtures[fid];
  if (fixture == null) {
    final mappedStatus = _bilyonerPeriodMap[periodType] ?? '';
    if (_isFinished(mappedStatus)) return;
    final esdlRaw = _int(v['esdl']) ?? 0;
    final nowMs   = DateTime.now().millisecondsSinceEpoch;
    if (esdlRaw > 0 && esdlRaw > nowMs + 60000) return;
    _addMissingFixture(fid, v);
    return;
  }

  final ts        = v['ts'] as Map<String, dynamic>?;
  final homeScore = _int(ts?['hs'] ?? v['home']) ?? 0;
  final awayScore = _int(ts?['as'] ?? v['away']) ?? 0;
  final status    = _bilyonerPeriodMap[periodType] ?? fixture.statusShort;

  _bilyonerUpdates++;
  fixture.statusShort = status;

  if (_isFinished(status)) {
    print('[$name] 🏁 [BLY] fid=$fid bitti');
    http.patch(
      Uri.parse('$_sbUrl/rest/v1/live_matches?fixture_id=eq.$fid'),
      headers: {..._sbHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode({
        'status_short': status,
        'home_score':   homeScore,
        'away_score':   awayScore,
        'updated_at':   DateTime.now().toIso8601String(),
      }),
    ).ignore();
    _fixtures.remove(fid);
    _nesineGuarded.remove(fid);
    return;
  }

  // ── Elapsed: Bilyoner HTTP endpoint'inden çek ────────────────
  // async olarak çalıştır, WS akışını bloklamıyor
  _fetchElapsed(fid, status).then((elapsed) {
    final fixture2 = _fixtures[fid]; // fetch bitince fixture hâlâ var mı?
    if (fixture2 == null) return;

    // Throttle: aynı elapsed'ı 30s içinde tekrar yazma
    final lastElapsed = _lastElapsedWritten[fid];
    final last        = _lastWrite[fid];
    final elapsedChanged = elapsed != null && elapsed != lastElapsed;
    if (!elapsedChanged &&
        last != null &&
        DateTime.now().difference(last).inSeconds < 30) return;

    _lastWrite[fid] = DateTime.now();
    if (elapsed != null) _lastElapsedWritten[fid] = elapsed;

    final isGuarded = _nesineGuarded.contains(fid);
    final data = <String, dynamic>{
      'status_short': status,
      'updated_at':   DateTime.now().toIso8601String(),
      if (elapsed != null) 'elapsed_time': elapsed,
      if (!isGuarded) ...{
        'home_score':   homeScore,
        'away_score':   awayScore,
        'score_source': 'bilyoner',
      },
    };

    // raw_data güncelle
    try {
      final raw = Map<String, dynamic>.from(jsonDecode(fixture2.rawData) as Map);
      (raw['fixture'] as Map)['status'] = {
        'long':    _statusLong[status] ?? status,
        'short':   status,
        'elapsed': elapsed,
        'extra':   null,
      };
      if (!isGuarded) {
        raw['goals'] = {'home': homeScore, 'away': awayScore};
        fixture2.homeScore = homeScore;
        fixture2.awayScore = awayScore;
      }
      data['raw_data'] = jsonEncode(raw);
      fixture2.rawData = data['raw_data'] as String;
    } catch (_) {}

    _sbPatch(fid, data);
    print('[$name] ⏱  [BLY] fid=$fid $status ${elapsed != null ? "$elapsed'" : "??"}'
          '${isGuarded ? "" : " $homeScore-$awayScore"}');
  });
}

// ── Bilyoner'dan gelen yeni maçı DB'ye ekle ──────────────────────
Future<void> _addMissingFixture(int fid, Map<String, dynamic> v) async {
  if (_fixtures.containsKey(fid)) return;
  if (_addingFids.contains(fid)) return;
  _addingFids.add(fid);

  final htn    = v['htn'] as String? ?? '';
  final atn    = v['atn'] as String? ?? '';
  final htpi   = _int(v['htpi']);
  final atpi   = _int(v['atpi']);
  final lgn    = v['lgn'] as String? ?? '';
  final compId = _int(v['competitionId'] ?? v['cid']) ?? 0;
  final esdl   = _int(v['esdl']) ?? 0;
  final periodType = v['periodType'] as String? ?? '';
  final status = _bilyonerPeriodMap[periodType] ?? '1H';

  if (_isFinished(status) || status == 'NS') {
    _addingFids.remove(fid);
    return;
  }

  final ts        = v['ts'] as Map?;
  final homeScore = _int(ts?['hs'] ?? v['home']) ?? 0;
  final awayScore = _int(ts?['as'] ?? v['away']) ?? 0;

  // Elapsed: hemen HTTP'den çek
  int? elapsed;
  if (status == 'HT') {
    elapsed = 45;
  } else if (status == 'BT') {
    elapsed = 105;
  } else if (status == 'P') {
    elapsed = 120;
  } else {
    elapsed = await _fetchElapsed(fid, status);
  }

  if (htn.isEmpty) { _addingFids.remove(fid); return; }

  final homeLogo = htpi != null ? 'https://im.mackolik.com/img/logo/buyuk/$htpi.gif' : '';
  final awayLogo = atpi != null ? 'https://im.mackolik.com/img/logo/buyuk/$atpi.gif' : '';
  final tsVal    = esdl > 0 ? (esdl > 9999999999 ? esdl ~/ 1000 : esdl) : 0;

  String dateStr = '';
  if (esdl > 0) {
    final utc = DateTime.fromMillisecondsSinceEpoch(esdl, isUtc: true);
    final tr  = utc.add(const Duration(hours: 3));
    final p   = (int n) => n.toString().padLeft(2, '0');
    dateStr   = '${tr.year}-${p(tr.month)}-${p(tr.day)}T${p(tr.hour)}:${p(tr.minute)}:00+03:00';
  }

  final rawData = jsonEncode({
    'fixture': {
      'id': fid, 'timestamp': tsVal, 'date': dateStr,
      'timezone': 'Europe/Istanbul', 'referee': null,
      'periods': {'first': null, 'second': null},
      'venue': {'id': null, 'name': null, 'city': null},
      'status': {
        'long': _statusLong[status] ?? status,
        'short': status, 'elapsed': elapsed, 'extra': null,
      },
    },
    'teams': {
      'home': {'id': htpi, 'name': htn, 'logo': homeLogo, 'winner': null},
      'away': {'id': atpi, 'name': atn, 'logo': awayLogo, 'winner': null},
    },
    'league': {'id': compId, 'name': lgn, 'logo': '', 'country': '', 'flag': null},
    'goals': {'home': homeScore, 'away': awayScore},
  });

  final data = {
    'fixture_id':   fid,
    'home_team':    htn,
    'away_team':    atn,
    'home_team_id': htpi,
    'away_team_id': atpi,
    'home_logo':    homeLogo,
    'away_logo':    awayLogo,
    'home_score':   homeScore,
    'away_score':   awayScore,
    'status_short': status,
    'elapsed_time': elapsed,
    'league_id':    compId,
    'league_name':  lgn,
    'league_logo':  '',
    'score_source': 'bilyoner',
    'raw_data':     rawData,
    'updated_at':   DateTime.now().toIso8601String(),
  };

  try {
    final res = await http.post(
      Uri.parse('$_sbUrl/rest/v1/live_matches'),
      headers: {..._sbHeaders(), 'Content-Type': 'application/json',
                 'Prefer': 'resolution=merge-duplicates,return=minimal'},
      body: jsonEncode(data),
    ).timeout(const Duration(seconds: 8));

    if (res.statusCode < 300) {
      print('[BLY] ➕ fid=$fid eklendi: $htn vs $atn [$status $elapsed\']');
      _fixtures[fid] = _LiveMatch(
        fixtureId: fid, homeTeam: htn, awayTeam: atn,
        homeScore: homeScore, awayScore: awayScore,
        statusShort: status, rawData: rawData,
        kickoffTs: tsVal > 0 ? tsVal : null,
      );
      _writeCount++;
    } else {
      print('[BLY] ⚠️ fid=$fid eklenemedi: ${res.statusCode}');
    }
  } catch (e) {
    print('[BLY] ❌ fid=$fid: $e');
  } finally {
    _addingFids.remove(fid);
  }
}

// ══════════════════════════════════════════════════════════════════
// NESİNE WS — sadece skor
// ══════════════════════════════════════════════════════════════════
Future<void> _nesineLoop(String name) async {
  while (true) {
    try { await _nesineConnect(name); } catch (e) { print('[$name] ❌ Nes $e'); }
    print('[$name] 🔄 Nesine koptu...');
    await Future.delayed(const Duration(seconds: 2));
  }
}

Future<void> _nesineConnect(String name) async {
  print('[$name] 🔌 Nesine bağlanıyor...');
  final ws = IOWebSocketChannel.connect(Uri.parse(_nesineWsUrl), headers: {
    'Origin':        'https://www.nesine.com',
    'User-Agent':    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/122.0.0.0',
    'Cache-Control': 'no-cache',
  });
  Timer? ping;
  void send(String s) { try { ws.sink.add(s); } catch (_) {} }
  try {
    await for (final raw in ws.stream) {
      final s = raw.toString();
      if (s == '2')           { send('3'); continue; }
      if (s == '3')           { continue; }
      if (s.startsWith('0'))  { send('40'); continue; }
      if (s.startsWith('40')) {
        print('[$name] ✅ Nesine bağlandı');
        send('42["joinroom","LiveBets_V3"]');
        ping?.cancel();
        ping = Timer.periodic(const Duration(seconds: 25), (_) {
          send('42["heartbeat"]');
        });
        continue;
      }
      if (s.startsWith('42')) _onNesineEvent(name, s.substring(2));
    }
  } catch (e) { print('[$name] [ERR] Nes $e'); }
  ping?.cancel();
  print('[$name] Nesine kapandı code=${ws.closeCode}');
}

void _onNesineEvent(String name, String payload) {
  try {
    final list = jsonDecode(payload) as List;
    if (list[0] != 'LiveBets' || list[1] is! List) return;
    for (final item in list[1] as List) {
      if (item is! Map) continue;
      if ((item['sportype'] ?? '').toString().toLowerCase() != 'football') continue;
      final mt  = _int(item['MT']);
      final m   = item['M'] as Map?;
      final bid = _int(m?['BID'] ?? item['bid'] ?? item['BID']);
      if (bid == null) continue;
      if (mt == 1) _onNesineStatus(name, bid, item);
      else if (m != null) _onNesineScore(name, bid, m, item);
    }
  } catch (_) {}
}

int? _resolveNesine(int bid, Map item) {
  if (_bidToFid.containsKey(bid)) return _bidToFid[bid];
  final nHome = _norm((item['HomeTeam'] ?? item['M']?['HN'] ?? '').toString());
  final nAway = _norm((item['AwayTeam'] ?? item['M']?['AN'] ?? '').toString());
  if (nHome.isEmpty) return null;
  _LiveMatch? best; double bestScore = 0;
  for (final f in _fixtures.values) {
    final hs  = _sim(nHome, _norm(f.homeTeam));
    final as_ = _sim(nAway, _norm(f.awayTeam));
    if (hs < 0.45 || as_ < 0.45) continue;
    final s = (hs + as_) / 2;
    if (s > bestScore) { bestScore = s; best = f; }
  }
  if (best != null && bestScore >= 0.55) {
    _bidToFid[bid] = best.fixtureId;
    best.nesineBid = bid;
    _nesineGuarded.add(best.fixtureId);
    print('   🔗 Nesine bid=$bid → fid=${best.fixtureId} '
          '(${bestScore.toStringAsFixed(2)}) ${best.homeTeam} vs ${best.awayTeam}');
    return best.fixtureId;
  }
  return null;
}

void _onNesineScore(String name, int bid, Map m, Map item) {
  if (!m.containsKey('TS') || m.containsKey('EN')) return;
  final h = _int(m['H']); final a = _int(m['A']);
  if (h == null || a == null || h > 30 || a > 30) return;

  final fid = _resolveNesine(bid, item);
  if (fid == null) return;
  final fixture = _fixtures[fid];
  if (fixture == null) return;
  if (h == fixture.homeScore && a == fixture.awayScore) return;

  _nesineGoals++;
  print('[$name] ⚽ GOL! [NES] fid=$fid ${fixture.homeTeam}'
        ' ${fixture.homeScore}-${fixture.awayScore} → $h-$a');
  fixture.homeScore = h;
  fixture.awayScore = a;

  final data = <String, dynamic>{
    'home_score':   h,
    'away_score':   a,
    'score_source': 'nesine',
    'updated_at':   DateTime.now().toIso8601String(),
  };
  try {
    final raw = Map<String, dynamic>.from(jsonDecode(fixture.rawData) as Map);
    raw['goals'] = {'home': h, 'away': a};
    data['raw_data'] = jsonEncode(raw);
    fixture.rawData = data['raw_data'] as String;
  } catch (_) {}
  _sbPatch(fid, data);
}

void _onNesineStatus(String name, int bid, Map item) {
  final fid = _resolveNesine(bid, item);
  if (fid == null) return;
  final fixture = _fixtures[fid];
  if (fixture == null) return;
  final stStr  = (item['ST'] ?? item['STL'] ?? '').toString().toUpperCase().trim();
  final stCode = _int(item['S']);
  String? status = _nesineStStrMap[stStr];
  if (status == null && stCode != null) status = _nesineStMap[stCode];
  if (status == null || status == fixture.statusShort) return;
  print('[$name] 📌 [NES] fid=$fid ${fixture.statusShort} → $status');
  fixture.statusShort = status;
  if (_isFinished(status)) {
    http.patch(
      Uri.parse('$_sbUrl/rest/v1/live_matches?fixture_id=eq.$fid'),
      headers: {..._sbHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode({
        'status_short': status,
        'updated_at':   DateTime.now().toIso8601String(),
      }),
    ).ignore();
    _fixtures.remove(fid);
    _bidToFid.remove(bid);
    _nesineGuarded.remove(fid);
  }
}

// ══════════════════════════════════════════════════════════════════
// FIXTURES YÜKLEME
// ══════════════════════════════════════════════════════════════════
Future<void> _loadFixtures() async {
  try {
    final res = await http.get(
      Uri.parse('$_sbUrl/rest/v1/live_matches'
          '?select=fixture_id,home_team,away_team,home_score,away_score,'
          'status_short,raw_data,nesine_bid'
          '&status_short=in.(1H,2H,HT,ET,BT,P,LIVE)'),
      headers: _sbHeaders(),
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return;
    final liveFids = <int>{};
    for (final r in (jsonDecode(res.body) as List).cast<Map>()) {
      final fid = r['fixture_id'] as int;
      final bid = _int(r['nesine_bid']);
      liveFids.add(fid);
      if (_fixtures.containsKey(fid)) {
        _fixtures[fid]!.homeScore = _int(r['home_score']) ?? _fixtures[fid]!.homeScore;
        _fixtures[fid]!.awayScore = _int(r['away_score']) ?? _fixtures[fid]!.awayScore;
      } else {
        int? kickoffTs;
        try {
          final rd = jsonDecode(r['raw_data'] as String? ?? '{}');
          final ts = _int(rd['fixture']?['timestamp']);
          kickoffTs = (ts != null && ts > 0) ? ts : null;
        } catch (_) {}

        _fixtures[fid] = _LiveMatch(
          fixtureId: fid,
          homeTeam:  (r['home_team'] ?? '').toString(),
          awayTeam:  (r['away_team'] ?? '').toString(),
          homeScore: _int(r['home_score']) ?? 0,
          awayScore: _int(r['away_score']) ?? 0,
          statusShort: (r['status_short'] ?? 'NS').toString(),
          rawData:   r['raw_data'] as String? ?? '{}',
          nesineBid: bid,
          kickoffTs: kickoffTs,
        );
      }
      if (bid != null) { _bidToFid[bid] = fid; _nesineGuarded.add(fid); }
    }
    _fixtures.removeWhere((fid, _) => !liveFids.contains(fid));
    _bidToFid.removeWhere((_, fid) => !liveFids.contains(fid));
    _nesineGuarded.removeWhere((fid) => !liveFids.contains(fid));
    print('📋 ${_fixtures.length} maç | ${_nesineGuarded.length} Nesine korumalı');
  } catch (e) { print('⚠️ loadFixtures: $e'); }
}

// ══════════════════════════════════════════════════════════════════
// STALE MAÇ TEMİZLEME
// ══════════════════════════════════════════════════════════════════
Future<void> _cleanStaleMatches() async {
  try {
    final res = await http.get(
      Uri.parse('$_sbUrl/rest/v1/live_matches'
          '?select=fixture_id,updated_at,status_short'
          '&status_short=in.(1H,2H,HT,ET,BT,P,LIVE)'),
      headers: _sbHeaders(),
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return;

    final now   = DateTime.now().toUtc();
    final stale = <int>[];
    for (final r in (jsonDecode(res.body) as List).cast<Map>()) {
      final fid        = _int(r['fixture_id']); if (fid == null) continue;
      final updatedStr = r['updated_at'] as String? ?? '';
      if (updatedStr.isEmpty) continue;
      final updated = DateTime.tryParse(updatedStr);
      if (updated == null) continue;
      if (now.difference(updated).inMinutes > 5) stale.add(fid);
    }
    if (stale.isEmpty) return;
    print('🧹 ${stale.length} stale maç temizleniyor: $stale');
    for (final fid in stale) {
      try {
        await http.delete(
          Uri.parse('$_sbUrl/rest/v1/live_matches?fixture_id=eq.$fid'),
          headers: _sbHeaders(),
        ).timeout(const Duration(seconds: 8));
        _fixtures.remove(fid);
        _nesineGuarded.remove(fid);
        _bidToFid.removeWhere((_, v) => v == fid);
        _lastElapsedFetch.remove(fid);
        _lastWrite.remove(fid);
        _lastElapsedWritten.remove(fid);
        print('🗑️ Stale silindi: fid=$fid');
      } catch (e) { print('⚠️ Stale silme ($fid): $e'); }
    }
  } catch (e) { print('⚠️ cleanStaleMatches: $e'); }
}

// ══════════════════════════════════════════════════════════════════
// SUPABASE
// ══════════════════════════════════════════════════════════════════
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

// ══════════════════════════════════════════════════════════════════
// YARDIMCI
// ══════════════════════════════════════════════════════════════════
bool _isFinished(String s) =>
    ['FT','AET','PEN','PST','CANC','ABD','AWD','WO'].contains(s);

Map<String, String> _sbHeaders() =>
    {'apikey': _sbKey, 'Authorization': 'Bearer $_sbKey', 'Prefer': 'return=minimal'};

int? _int(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.toInt();
  return int.tryParse(v.toString());
}

String _norm(String s) => s.toLowerCase()
    .replaceAll('ı','i').replaceAll('ğ','g').replaceAll('ü','u')
    .replaceAll('ş','s').replaceAll('ö','o').replaceAll('ç','c')
    .replaceAll('é','e').replaceAll('è','e').replaceAll('ê','e').replaceAll('ë','e')
    .replaceAll('á','a').replaceAll('à','a').replaceAll('â','a').replaceAll('ä','a').replaceAll('ã','a')
    .replaceAll('ó','o').replaceAll('ò','o').replaceAll('ô','o').replaceAll('õ','o')
    .replaceAll('ú','u').replaceAll('ù','u').replaceAll('û','u')
    .replaceAll('í','i').replaceAll('ì','i').replaceAll('î','i')
    .replaceAll('ñ','n').replaceAll('ø','o').replaceAll('å','a')
    .replaceAll('ć','c').replaceAll('č','c').replaceAll('ž','z').replaceAll('š','s')
    .replaceAll(RegExp(r'[^\w\s]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

double _sim(String a, String b) {
  if (a == b) return 1.0;
  if (a.contains(b) || b.contains(a)) return 0.9;
  final w1 = a.split(' ').where((t) => t.length > 1).toSet();
  final w2 = b.split(' ').where((t) => t.length > 1).toSet();
  if (w1.isEmpty || w2.isEmpty) return 0.0;
  final j = w1.intersection(w2).length / w1.union(w2).length;
  if (j >= 0.5) return 0.7 + j * 0.2;
  if (a.length >= 3 && b.length >= 3 && a.substring(0,3) == b.substring(0,3)) return 0.6;
  return j * 0.5;
}
