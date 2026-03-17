// nesine_ws_test.dart v3
// 1) GetLiveBetResults → canlı maç listesi + BID al
// 2) WS bağlan joinroom "LiveBets_V3" → skor event'lerini dinle

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';

const _wsUrl = 'wss://rt.nesine.com/socket.io/'
    '?platformid=1'
    '&userAgent=Mozilla%2F5.0%20(Windows%20NT%2010.0%3B%20Win64%3B%20x64)%20'
    'AppleWebKit%2F537.36%20(KHTML%2C%20like%20Gecko)%20'
    'Chrome%2F122.0.0.0%20Safari%2F537.36'
    '&EIO=4'
    '&transport=websocket';

final _headers = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/122.0.0.0',
  'Accept': 'application/json, text/javascript, */*; q=0.01',
  'Accept-Language': 'tr-TR,tr;q=0.9',
  'Referer': 'https://www.nesine.com/iddaa/canli-iddaa-canli-bahis',
  'X-Requested-With': 'XMLHttpRequest',
  'Origin': 'https://www.nesine.com',
};

Future<void> main() async {
  print('╔══════════════════════════════════════╗');
  print('║  🧪 Nesine Test v3                   ║');
  print('╚══════════════════════════════════════╝\n');

  // ── ADIM 1: GetLiveBetResults → canlı maç listesi ──────────
  print('📡 GetLiveBetResults çekiliyor...');
  try {
    final res = await http.post(
      Uri.parse('https://www.nesine.com/LiveScore/GetLiveBetResults'),
      headers: _headers,
    ).timeout(const Duration(seconds: 10));

    print('   HTTP ${res.statusCode} | ${res.body.length} bytes');
    if (res.statusCode == 200 && res.body.isNotEmpty) {
      final data = jsonDecode(res.body);
      if (data is Map) {
        print('   ${data.length} maç bulundu');
        // İlk 3 maçı göster
        int count = 0;
        data.forEach((key, val) {
          if (count++ >= 3) return;
          final bid  = val['BID'] ?? key;
          final home = val['HN'] ?? val['HomeTeam'] ?? val['HT'] ?? '?';
          final away = val['AN'] ?? val['AwayTeam'] ?? val['AT'] ?? '?';
          final hs   = val['HS'] ?? val['HomeScore'] ?? '?';
          final as_  = val['AS'] ?? val['AwayScore'] ?? '?';
          final st   = val['Status'] ?? val['ST'] ?? '?';
          print('   BID=$bid | $home $hs-$as_ $away | status=$st');
          // Tüm alanları göster — yapıyı öğrenmek için
          if (count == 1) {
            print('   Tüm alanlar: ${val.keys.toList()}');
          }
        });
      } else if (data is List) {
        print('   Liste formatı: ${data.length} item');
        if (data.isNotEmpty) print('   İlk item: ${data.first}');
      } else {
        print('   Beklenmedik format: ${res.body.substring(0, 200)}');
      }
    } else {
      print('   HATA veya boş response: ${res.body.substring(0, res.body.length.clamp(0, 300))}');
    }
  } catch (e) {
    print('   GetLiveBetResults hatası: $e');
  }

  print('');

  // ── ADIM 2: ls.nesine.com GetLiveMatchesByBidList ──────────
  print('📡 GetLiveMatchesByBidList test ediliyor...');
  try {
    // sportTypeList ile tüm futbol maçlarını al
    final res = await http.get(
      Uri.parse('https://ls.nesine.com/api/v2/LiveScore/GetLiveMatchesByBidList'
          '?sportTypeList=1'),  // 1 = Futbol
      headers: _headers,
    ).timeout(const Duration(seconds: 10));

    print('   HTTP ${res.statusCode} | ${res.body.length} bytes');
    if (res.statusCode == 200) {
      print('   Response: ${res.body.substring(0, res.body.length.clamp(0, 500))}');
    }
  } catch (e) {
    print('   GetLiveMatchesByBidList hatası: $e');
  }

  print('');

  // ── ADIM 3: WebSocket → LiveBets_V3 ────────────────────────
  print('🔌 WebSocket bağlanıyor...');
  final channel = IOWebSocketChannel.connect(
    Uri.parse(_wsUrl),
    headers: {
      'Origin': 'https://www.nesine.com',
      'User-Agent': 'Mozilla/5.0 Chrome/122.0.0.0',
    },
  );

  Timer(const Duration(seconds: 45), () {
    print('\n⏰ 45sn doldu, çıkılıyor...');
    channel.sink.close();
    exit(0);
  });

  int msgCount = 0;
  await for (final raw in channel.stream) {
    msgCount++;
    final str = raw.toString();

    if (str == '2') { channel.sink.add('3'); continue; }

    if (str.startsWith('0')) {
      try {
        final d = jsonDecode(str.substring(1)) as Map;
        print('🤝 sid=${d['sid']}');
        channel.sink.add('40');
      } catch (_) {}
      continue;
    }

    if (str.startsWith('40')) {
      print('✅ Socket.IO bağlandı!');
      channel.sink.add('42["joinroom","LiveBets_V3"]');
      print('📤 joinroom "LiveBets_V3"\n');
      continue;
    }

    if (str.startsWith('42')) {
      try {
        final list = jsonDecode(str.substring(2)) as List;
        if (list[0] != 'LiveBets') continue;
        final items = list[1] as List;

        for (final item in items) {
          if (item is! Map) continue;
          final sportype = (item['sportype'] ?? '').toString();
          final mt  = item['MT'];
          final m   = item['M'] as Map?;
          final bid = item['bid'] ?? m?['BID'];

          if (sportype != 'Football') continue;

          print('[$msgCount] MT=$mt BID=$bid');
          if (m != null) {
            // MT=11: skor
            if (mt == 11) print('  ⚽ H=${m['H']} A=${m['A']} T=${m['T']}');
            // Tüm alanları göster — tanımadığımız MT'ler için
            else print('  M keys: ${m.keys.toList()} | ${jsonEncode(m).substring(0, jsonEncode(m).length.clamp(0,150))}');
          }
        }
      } catch (e) {
        print('parse err: $e');
      }
    }
  }
}
