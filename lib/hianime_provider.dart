import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

// ============================================================================
// Models
// ============================================================================
class Anime {
  final String id; // "one-piece-100"
  final String title;
  final String? cover;
  final String? subtitle;
  const Anime({required this.id, required this.title, this.cover, this.subtitle});

  /// Numeric HiAnime id (after the last dash).
  String get numericId => id.substring(id.lastIndexOf('-') + 1);

  Map<String, dynamic> toMap() =>
      {'id': id, 'title': title, 'cover': cover, 'subtitle': subtitle};
  factory Anime.fromMap(Map m) => Anime(
      id: m['id'], title: m['title'], cover: m['cover'], subtitle: m['subtitle']);
}

class Episode {
  final String id; // numeric HiAnime episode id
  final int number;
  final String title;
  final bool filler;
  const Episode({required this.id, required this.number, required this.title, this.filler = false});
}

class ScheduleItem {
  final Anime anime;
  final String time;
  final String episodeLabel;
  const ScheduleItem(this.anime, this.time, this.episodeLabel);
}

class ServerMirror {
  final String dataId; // value for /ajax/v2/episode/sources?id=
  final String serverId; // HiAnime internal server id
  final String name; // HD-1, HD-2, Megaplay, Vidhawk, Gogo ...
  final String type; // sub | dub | raw
  const ServerMirror({
    required this.dataId,
    required this.serverId,
    required this.name,
    required this.type,
  });
  @override
  String toString() => '$name ($type)';
}

class VideoSource {
  final String url;
  final bool isM3u8;
  final String quality;
  const VideoSource(this.url, {this.isM3u8 = true, this.quality = 'auto'});
}

class SubtitleTrackInfo {
  final String url;
  final String label;
  final bool isDefault;
  const SubtitleTrackInfo(this.url, this.label, {this.isDefault = false});
}

class ExtractedStream {
  final List<VideoSource> sources;
  final List<SubtitleTrackInfo> subtitles;
  final Map<String, String> headers;
  final Duration? introStart, introEnd, outroStart, outroEnd;
  String server;
  ExtractedStream({
    required this.sources,
    this.subtitles = const [],
    this.headers = const {},
    this.introStart,
    this.introEnd,
    this.outroStart,
    this.outroEnd,
    this.server = '',
  });
}

class ProviderException implements Exception {
  final String message;
  ProviderException(this.message);
  @override
  String toString() => 'ProviderException: $message';
}

// ============================================================================
// Generic provider contract (so more sites can be added later)
// ============================================================================
abstract class AnimeProvider {
  String get name;
  Future<List<Anime>> search(String query, {int page = 1});
  Future<List<Anime>> recentlyUpdated({int page = 1});
  Future<List<ScheduleItem>> schedule(DateTime date);
  Future<List<Episode>> episodes(String animeId);
  Future<List<ServerMirror>> servers(String episodeId);
  Future<ExtractedStream> extractStream(String episodeId, {String category = 'sub'});
}

// ============================================================================
// Extractor framework
// ============================================================================
abstract class StreamExtractor {
  String get name;
  bool supports(Uri embed);
  Future<ExtractedStream> extract(Uri embed, Dio dio);
}

const _ua =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/126.0.0.0 Mobile Safari/537.36';

Duration? _sec(dynamic v) => v == null ? null : Duration(seconds: (v as num).toInt());

List<SubtitleTrackInfo> _parseTracks(dynamic tracks) {
  final out = <SubtitleTrackInfo>[];
  if (tracks is List) {
    for (final t in tracks) {
      if (t is Map && (t['kind'] == 'captions' || t['kind'] == 'subtitles') && t['file'] != null) {
        out.add(SubtitleTrackInfo(t['file'], t['label'] ?? 'Unknown',
            isDefault: t['default'] == true));
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// MegaCloud family (HD-1 / HD-2 / rapid-cloud / vidcloud / rabbitstream)
// ---------------------------------------------------------------------------
class MegaCloudExtractor extends StreamExtractor {
  MegaCloudExtractor({this.keyUrl});

  /// URL returning the current decryption passphrase (JSON {"key": "..."} or
  /// plain text). Keep it configurable: the key rotates upstream.
  String? keyUrl;
  String? _cachedKey;

  @override
  String get name => 'MegaCloud';

  @override
  bool supports(Uri e) {
    final h = e.host;
    return h.contains('megacloud') ||
        h.contains('rapid-cloud') ||
        h.contains('rabbitstream') ||
        h.contains('vidcloud') ||
        e.path.contains('/embed-2/');
  }

  @override
  Future<ExtractedStream> extract(Uri embed, Dio dio) async {
    final origin = '${embed.scheme}://${embed.host}';
    final headers = {'Referer': '$origin/', 'User-Agent': _ua};
    final id = embed.pathSegments.where((s) => s.isNotEmpty).last;

    final page = await dio.getUri<String>(embed,
        options: Options(headers: headers, responseType: ResponseType.plain));
    final key = _findClientKey(page.data ?? '');
    if (key == null) throw ProviderException('MegaCloud: client key not found');

    final segs = embed.pathSegments.where((s) => s.isNotEmpty).toList();
    // /embed-2/v2/e-1/<id>  ->  /embed-2/v2/e-1/getSources
    final apiBase = '$origin/${segs.sublist(0, segs.length - 1).join('/')}/getSources';

    final res = await dio.get(apiBase,
        queryParameters: {'id': id, '_k': key},
        options: Options(headers: {
          ...headers,
          'X-Requested-With': 'XMLHttpRequest',
          'Accept': 'application/json',
        }));
    final data = res.data is String ? jsonDecode(res.data) : res.data;

    dynamic sources = data['sources'];
    if (sources is String) {
      final pass = await _passphrase(dio);
      sources = _decrypt(sources, pass + '');
    }
    final list = <VideoSource>[];
    for (final s in (sources as List)) {
      final f = s['file'] as String;
      list.add(VideoSource(f, isM3u8: s['type'] == 'hls' || f.contains('.m3u8')));
    }
    return ExtractedStream(
      sources: list,
      subtitles: _parseTracks(data['tracks']),
      headers: {'Referer': '$origin/', 'User-Agent': _ua},
      introStart: _sec(data['intro']?['start']),
      introEnd: _sec(data['intro']?['end']),
      outroStart: _sec(data['outro']?['start']),
      outroEnd: _sec(data['outro']?['end']),
    );
  }

  String? _findClientKey(String h) {
    final pats = <RegExp>[
      RegExp(r'<meta[^>]+name="_gg_fb"[^>]+content="([A-Za-z0-9]+)"'),
      RegExp(r'data-dpi="([A-Za-z0-9]+)"'),
      RegExp(r'_is_th:([A-Za-z0-9]+)'),
      RegExp(r'<!--\s*_is_th:([A-Za-z0-9]+)\s*-->'),
    ];
    for (final p in pats) {
      final m = p.firstMatch(h);
      if (m != null) return m.group(1);
    }
    // window._lk_db = {x: "..", y: "..", z: ".."}
    final lk = RegExp(r'x:\s*"([^"]+)"\s*,\s*y:\s*"([^"]+)"\s*,\s*z:\s*"([^"]+)"')
        .firstMatch(h);
    if (lk != null) return '${lk.group(1)}${lk.group(2)}${lk.group(3)}';
    final k48 = RegExp(r'\b[A-Za-z0-9]{48}\b').firstMatch(h);
    return k48?.group(0);
  }

  Future<String> _passphrase(Dio dio) async {
    if (_cachedKey != null) return _cachedKey!;
    if (keyUrl == null || keyUrl!.isEmpty) {
      throw ProviderException(
          'Encrypted MegaCloud source: set a key URL in Settings > Providers.');
    }
    final r = await dio.get<String>(keyUrl!,
        options: Options(responseType: ResponseType.plain));
    var body = (r.data ?? '').trim();
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        body = (j['key'] ?? j['mega'] ?? j.values.first).toString();
      } else if (j is String) {
        body = j;
      }
    } catch (_) {}
    return _cachedKey = body.trim();
  }

  /// CryptoJS-compatible AES-256-CBC (OpenSSL "Salted__" + EVP_BytesToKey/MD5).
  List<dynamic> _decrypt(String b64, String pass) {
    final raw = base64.decode(b64);
    final salt = raw.sublist(8, 16);
    final data = raw.sublist(16);
    final d = <int>[];
    var prev = <int>[];
    while (d.length < 48) {
      prev = md5.convert([...prev, ...utf8.encode(pass), ...salt]).bytes;
      d.addAll(prev);
    }
    final key = enc.Key(Uint8List.fromList(d.sublist(0, 32)));
    final iv = enc.IV(Uint8List.fromList(d.sublist(32, 48)));
    final out = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc))
        .decrypt(enc.Encrypted(Uint8List.fromList(data)), iv: iv);
    return jsonDecode(out) as List<dynamic>;
  }
}

// ---------------------------------------------------------------------------
// Megaplay / Vidwish style players (unencrypted JSON)
// ---------------------------------------------------------------------------
class MegaplayExtractor extends StreamExtractor {
  @override
  String get name => 'Megaplay';

  @override
  bool supports(Uri e) =>
      e.host.contains('megaplay') || e.host.contains('vidwish') || e.path.contains('/stream/s-');

  @override
  Future<ExtractedStream> extract(Uri embed, Dio dio) async {
    final origin = '${embed.scheme}://${embed.host}';
    final headers = {'Referer': '$origin/', 'User-Agent': _ua};
    final page = await dio.getUri<String>(embed,
        options: Options(headers: headers, responseType: ResponseType.plain));
    final m = RegExp(r'data-id="(\d+)"').firstMatch(page.data ?? '');
    if (m == null) throw ProviderException('Megaplay: data-id missing');

    final res = await dio.get('$origin/stream/getSources',
        queryParameters: {'id': m.group(1)},
        options: Options(headers: {
          ...headers,
          'X-Requested-With': 'XMLHttpRequest',
        }));
    final data = res.data is String ? jsonDecode(res.data) : res.data;
    final src = data['sources'];
    final file = src is Map ? src['file'] : (src is List && src.isNotEmpty ? src.first['file'] : null);
    if (file == null) throw ProviderException('Megaplay: no sources');
    return ExtractedStream(
      sources: [VideoSource(file, isM3u8: file.toString().contains('.m3u8'))],
      subtitles: _parseTracks(data['tracks']),
      headers: headers,
      introStart: _sec(data['intro']?['start']),
      introEnd: _sec(data['intro']?['end']),
      outroStart: _sec(data['outro']?['start']),
      outroEnd: _sec(data['outro']?['end']),
    );
  }
}

// ---------------------------------------------------------------------------
// Generic fallback (Gogo / Vidhawk / unknown iframes): sniff media URLs
// ---------------------------------------------------------------------------
class GenericIframeExtractor extends StreamExtractor {
  @override
  String get name => 'Generic';

  @override
  bool supports(Uri e) => true;

  @override
  Future<ExtractedStream> extract(Uri embed, Dio dio) async {
    final origin = '${embed.scheme}://${embed.host}';
    final headers = {'Referer': '$origin/', 'User-Agent': _ua};
    final page = await dio.getUri<String>(embed,
        options: Options(headers: headers, responseType: ResponseType.plain));
    final body = (page.data ?? '').replaceAll(r'\/', '/');

    final media = RegExp(r'''https?://[^\s"'<>\\]+?\.(?:m3u8|mp4)[^\s"'<>\\]*''')
        .allMatches(body)
        .map((m) => m.group(0)!)
        .toSet()
        .toList();
    if (media.isEmpty) throw ProviderException('${embed.host}: no media URL found');

    final subs = RegExp(r'''https?://[^\s"'<>\\]+?\.(?:vtt|srt)[^\s"'<>\\]*''')
        .allMatches(body)
        .map((m) => SubtitleTrackInfo(m.group(0)!, 'Subtitle'))
        .toList();

    return ExtractedStream(
      sources: media.map((u) => VideoSource(u, isM3u8: u.contains('.m3u8'))).toList(),
      subtitles: subs,
      headers: headers,
    );
  }
}

// ============================================================================
// HiAnime provider
// ============================================================================
class HiAnimeProvider extends AnimeProvider {
  HiAnimeProvider({
    String baseUrl = 'https://hianime.to',
    String? megacloudKeyUrl,
    Dio? dio,
  })  : _baseUrl = baseUrl,
        _megacloud = MegaCloudExtractor(keyUrl: megacloudKeyUrl) {
    _dio = dio ?? Dio();
    _dio.options
      ..connectTimeout = const Duration(seconds: 20)
      ..receiveTimeout = const Duration(seconds: 20)
      ..followRedirects = true
      ..headers = {'User-Agent': _ua, 'Accept-Language': 'en-US,en;q=0.9'};
    extractors = [_megacloud, MegaplayExtractor(), GenericIframeExtractor()];
  }

  late final Dio _dio;
  String _baseUrl;
  final MegaCloudExtractor _megacloud;
  late List<StreamExtractor> extractors;

  /// Mirror priority (substring match, lowercase). Edit freely.
  List<String> serverPriority = [
    'hd-1',
    'hd-2',
    'megaplay',
    'vidhawk',
    'gogo',
    'vidwish',
    'hd-3',
  ];

  @override
  String get name => 'HiAnime';

  String get baseUrl => _baseUrl;
  set baseUrl(String v) => _baseUrl = v.replaceAll(RegExp(r'/+$'), '');
  set megacloudKeyUrl(String? v) {
    _megacloud.keyUrl = v;
    _megacloud._cachedKey = null;
  }

  Map<String, String> get _ajaxHeaders => {
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': '$_baseUrl/',
        'Accept': 'application/json, text/javascript, */*; q=0.01',
      };

  Future<Document> _doc(String path, {Map<String, dynamic>? q}) async {
    final r = await _dio.get<String>('$_baseUrl$path',
        queryParameters: q,
        options: Options(responseType: ResponseType.plain, headers: {'Referer': '$_baseUrl/'}));
    return html.parse(r.data ?? '');
  }

  Future<Document> _ajaxHtml(String path, {Map<String, dynamic>? q}) async {
    final r = await _dio.get('$_baseUrl$path',
        queryParameters: q, options: Options(headers: _ajaxHeaders));
    final j = r.data is String ? jsonDecode(r.data) : r.data;
    if (j['status'] != true) throw ProviderException('Ajax $path failed');
    return html.parse(j['html'] as String);
  }

  // ---- listing ------------------------------------------------------------
  List<Anime> _parseCards(Document d) {
    final out = <Anime>[];
    for (final it in d.querySelectorAll('.flw-item')) {
      final a = it.querySelector('.film-name a');
      if (a == null) continue;
      final href = a.attributes['href'] ?? '';
      final id = href.split('?').first.replaceFirst('/', '');
      if (id.isEmpty) continue;
      final img = it.querySelector('img.film-poster-img');
      final sub = it.querySelector('.tick-sub')?.text.trim();
      final eps = it.querySelector('.tick-eps')?.text.trim();
      out.add(Anime(
        id: id,
        title: (a.attributes['title'] ?? a.text).trim(),
        cover: img?.attributes['data-src'] ?? img?.attributes['src'],
        subtitle: [if (sub != null) 'SUB $sub', if (eps != null) 'EP $eps'].join(' • '),
      ));
    }
    return out;
  }

  @override
  Future<List<Anime>> search(String query, {int page = 1}) async =>
      _parseCards(await _doc('/search', q: {'keyword': query, 'page': page}));

  @override
  Future<List<Anime>> recentlyUpdated({int page = 1}) async =>
      _parseCards(await _doc('/recently-updated', q: {'page': page}));

  @override
  Future<List<ScheduleItem>> schedule(DateTime date) async {
    final d = await _ajaxHtml('/ajax/schedule/list', q: {
      'tzOffset': -date.timeZoneOffset.inMinutes,
      'date': '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}',
    });
    final out = <ScheduleItem>[];
    for (final li in d.querySelectorAll('li')) {
      final a = li.querySelector('a.tsl-link') ?? li.querySelector('a');
      if (a == null) continue;
      final id = (a.attributes['href'] ?? '').replaceFirst('/', '');
      final title = li.querySelector('.film-name')?.text.trim() ?? '';
      if (id.isEmpty || title.isEmpty) continue;
      out.add(ScheduleItem(
        Anime(id: id, title: title),
        li.querySelector('.time')?.text.trim() ?? '',
        li.querySelector('.btn')?.text.trim() ?? '',
      ));
    }
    return out;
  }

  // ---- episodes -----------------------------------------------------------
  @override
  Future<List<Episode>> episodes(String animeId) async {
    final numeric = animeId.substring(animeId.lastIndexOf('-') + 1);
    final d = await _ajaxHtml('/ajax/v2/episode/list/$numeric');
    final out = <Episode>[];
    for (final a in d.querySelectorAll('a.ep-item')) {
      final id = a.attributes['data-id'];
      final n = int.tryParse(a.attributes['data-number'] ?? '');
      if (id == null || n == null) continue;
      out.add(Episode(
        id: id,
        number: n,
        title: (a.attributes['title'] ?? 'Episode $n').trim(),
        filler: a.classes.contains('ssl-item-filler'),
      ));
    }
    return out;
  }

  // ---- server mirrors -----------------------------------------------------
  @override
  Future<List<ServerMirror>> servers(String episodeId) async {
    final d = await _ajaxHtml('/ajax/v2/episode/servers', q: {'episodeId': episodeId});
    final out = <ServerMirror>[];
    for (final el in d.querySelectorAll('.server-item')) {
      final dataId = el.attributes['data-id'];
      if (dataId == null) continue;
      out.add(ServerMirror(
        dataId: dataId,
        serverId: el.attributes['data-server-id'] ?? '',
        type: (el.attributes['data-type'] ?? 'sub').toLowerCase(),
        name: (el.querySelector('a')?.text ?? el.text).trim(),
      ));
    }
    return out;
  }

  /// Resolves a mirror to its iframe/embed URL.
  Future<Uri> resolveEmbed(ServerMirror s) async {
    final r = await _dio.get('$_baseUrl/ajax/v2/episode/sources',
        queryParameters: {'id': s.dataId}, options: Options(headers: _ajaxHeaders));
    final j = r.data is String ? jsonDecode(r.data) : r.data;
    final link = j['link'] as String?;
    if (link == null) throw ProviderException('No embed link for $s');
    return Uri.parse(link);
  }

  int _rank(ServerMirror s) {
    final n = s.name.toLowerCase();
    final i = serverPriority.indexWhere((p) => n.contains(p));
    return i < 0 ? serverPriority.length : i;
  }

  /// Tries mirrors in priority order until one yields playable sources.
  @override
  Future<ExtractedStream> extractStream(String episodeId, {String category = 'sub'}) async {
    var list = await servers(episodeId);
    final preferred = list.where((s) => s.type == category).toList();
    if (preferred.isNotEmpty) list = preferred;
    list.sort((a, b) => _rank(a).compareTo(_rank(b)));

    final errors = <String>[];
    for (final s in list) {
      try {
        final embed = await resolveEmbed(s);
        final ex = extractors.firstWhere((e) => e.supports(embed));
        final stream = await ex.extract(embed, _dio);
        if (stream.sources.isNotEmpty) {
          stream.server = s.name;
          return stream;
        }
      } catch (e) {
        errors.add('${s.name}: $e');
      }
    }
    throw ProviderException('All mirrors failed.\n${errors.join('\n')}');
  }
}
