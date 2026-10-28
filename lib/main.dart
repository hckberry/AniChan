import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import 'discord_rpc_service.dart';
import 'hianime_provider.dart';

// Register an AniList client with redirect URI  anichan://auth
const kAniListClientId = 'YOUR_ANILIST_CLIENT_ID';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Hive.initFlutter();
  final box = await Hive.openBox('anichan');

  final state = AppState(box);
  final discord = DiscordRpcService(DiscordRpcConfig.fromMap(box.get('discord')));
  final provider = HiAnimeProvider(
    baseUrl: box.get('hianimeUrl', defaultValue: 'https://hianime.to'),
    megacloudKeyUrl: box.get('megacloudKeyUrl'),
  );
  DiscordBackground.init();
  if (discord.config.enabled) discord.connect();

  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: state),
      ChangeNotifierProvider.value(value: discord),
      Provider<HiAnimeProvider>.value(value: provider),
    ],
    child: const AniChanApp(),
  ));
}

// ============================================================================
// State
// ============================================================================
class AppState extends ChangeNotifier {
  AppState(this.box);
  final Box box;

  Color get background => Color(box.get('bg', defaultValue: 0xFF0E0E14));
  Future<void> setBackground(Color c) async {
    await box.put('bg', c.value);
    notifyListeners();
  }

  String? get aniListToken => box.get('anilist_token');
  Future<void> setAniListToken(String? t) async {
    t == null ? await box.delete('anilist_token') : await box.put('anilist_token', t);
    notifyListeners();
  }

  // ----- continue watching --------------------------------------------------
  List<Map> get continueWatching =>
      (box.get('continue', defaultValue: <dynamic>[]) as List)
          .map((e) => Map.from(e))
          .toList();

  Future<void> saveProgress(Anime a, Episode e, int posMs, int durMs) async {
    final list = continueWatching..removeWhere((m) => m['animeId'] == a.id);
    list.insert(0, {
      'animeId': a.id,
      'title': a.title,
      'cover': a.cover,
      'episodeId': e.id,
      'episode': e.number,
      'posMs': posMs,
      'durMs': durMs,
    });
    await box.put('continue', list.take(30).toList());
    notifyListeners();
  }

  // ----- downloads (entries written by a downloader; list/play/delete) ------
  List<Map> get downloads =>
      (box.get('downloads', defaultValue: <dynamic>[]) as List).map((e) => Map.from(e)).toList();
  Future<void> removeDownload(int i) async {
    final l = downloads..removeAt(i);
    await box.put('downloads', l);
    notifyListeners();
  }
}

// ============================================================================
// AniList (implicit-grant OAuth + progress sync)
// ============================================================================
class AniListService {
  static final _dio = Dio();

  static Future<String> login() async {
    final url = 'https://anilist.co/api/v2/oauth/authorize'
        '?client_id=$kAniListClientId&response_type=token';
    final result = await FlutterWebAuth2.authenticate(url: url, callbackUrlScheme: 'anichan');
    final frag = Uri.parse(result).fragment;
    final token = Uri.splitQueryString(frag)['access_token'];
    if (token == null) throw Exception('AniList login failed');
    return token;
  }

  static Future<Map?> _gql(String token, String q, Map<String, dynamic> v) async {
    final r = await _dio.post('https://graphql.anilist.co',
        data: {'query': q, 'variables': v},
        options: Options(headers: {'Authorization': 'Bearer $token'}));
    return r.data['data'] as Map?;
  }

  /// Finds the AniList media by title, then saves episode progress.
  static Future<void> syncProgress(String token, String title, int episode) async {
    final found = await _gql(token,
        r'query($s:String){Media(search:$s,type:ANIME){id episodes}}', {'s': title});
    final media = found?['Media'];
    if (media == null) return;
    final total = media['episodes'] as int?;
    await _gql(
        token,
        r'mutation($id:Int,$p:Int,$st:MediaListStatus){SaveMediaListEntry(mediaId:$id,progress:$p,status:$st){id}}',
        {
          'id': media['id'],
          'p': episode,
          'st': (total != null && episode >= total) ? 'COMPLETED' : 'CURRENT',
        });
  }
}

// ============================================================================
// App shell
// ============================================================================
class AniChanApp extends StatelessWidget {
  const AniChanApp({super.key});
  @override
  Widget build(BuildContext context) {
    final bg = context.watch<AppState>().background;
    return MaterialApp(
      title: 'AniChan',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFFF6FA5),
        scaffoldBackgroundColor: bg,
        canvasColor: bg,
        appBarTheme: AppBarTheme(backgroundColor: bg, elevation: 0),
        navigationBarTheme: NavigationBarThemeData(backgroundColor: bg),
        useMaterial3: true,
      ),
      home: const RootPage(),
    );
  }
}

class RootPage extends StatefulWidget {
  const RootPage({super.key});
  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int _i = 0;
  @override
  Widget build(BuildContext context) {
    const pages = [HomePage(), SchedulePage(), DownloadsPage(), SettingsPage()];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _i, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _i,
        onDestinationSelected: (v) => setState(() => _i = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.calendar_month_outlined), label: 'Schedule'),
          NavigationDestination(icon: Icon(Icons.download_outlined), label: 'Offline'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
        ],
      ),
    );
  }
}

// ============================================================================
// Home: search + continue watching
// ============================================================================
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _ctl = TextEditingController();
  List<Anime>? _results;
  bool _loading = false;
  String? _error;

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) return setState(() => _results = null);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await context.read<HiAnimeProvider>().search(q.trim());
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cw = context.watch<AppState>().continueWatching;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SearchBar(
          controller: _ctl,
          hintText: 'Search anime',
          leading: const Icon(Icons.search),
          onSubmitted: _search,
          trailing: [
            if (_ctl.text.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  _ctl.clear();
                  setState(() => _results = null);
                },
              )
          ],
        ),
        const SizedBox(height: 16),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        if (_results != null) ...[
          AnimeGrid(items: _results!),
        ] else if (cw.isNotEmpty) ...[
          Text('Continue Watching', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(
            height: 200,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: cw.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, i) => _ContinueCard(cw[i]),
            ),
          ),
        ] else
          const Padding(
            padding: EdgeInsets.only(top: 80),
            child: Center(child: Text('Search for something to watch')),
          ),
      ],
    );
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard(this.m);
  final Map m;
  @override
  Widget build(BuildContext context) {
    final anime = Anime(id: m['animeId'], title: m['title'], cover: m['cover']);
    final progress = (m['durMs'] ?? 0) > 0 ? (m['posMs'] / m['durMs']).clamp(0.0, 1.0) : 0.0;
    return GestureDetector(
      onTap: () async {
        final eps = await context.read<HiAnimeProvider>().episodes(anime.id);
        final ep = eps.firstWhere((e) => e.id == m['episodeId'], orElse: () => eps.first);
        if (!context.mounted) return;
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => PlayerPage(anime: anime, episode: ep, resumeMs: m['posMs'])));
      },
      child: SizedBox(
        width: 130,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _Poster(m['cover'])),
          LinearProgressIndicator(value: progress.toDouble()),
          const SizedBox(height: 4),
          Text(m['title'], maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('Episode ${m['episode']}', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster(this.url);
  final String? url;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: url == null
            ? Container(color: Colors.white10)
            : CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                width: double.infinity,
                errorWidget: (_, __, ___) => Container(color: Colors.white10),
              ),
      );
}

class AnimeGrid extends StatelessWidget {
  const AnimeGrid({super.key, required this.items});
  final List<Anime> items;
  @override
  Widget build(BuildContext context) => GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: items.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3, childAspectRatio: 0.58, mainAxisSpacing: 12, crossAxisSpacing: 10),
        itemBuilder: (_, i) {
          final a = items[i];
          return GestureDetector(
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => DetailPage(anime: a))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _Poster(a.cover)),
              const SizedBox(height: 4),
              Text(a.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12)),
            ]),
          );
        },
      );
}

// ============================================================================
// Detail + episodes
// ============================================================================
class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.anime});
  final Anime anime;
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late final Future<List<Episode>> _eps =
      context.read<HiAnimeProvider>().episodes(widget.anime.id);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.anime.title, maxLines: 1)),
        body: FutureBuilder<List<Episode>>(
          future: _eps,
          builder: (_, s) {
            if (s.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (s.hasError) return Center(child: Text('${s.error}'));
            final eps = s.data!;
            return ListView.builder(
              itemCount: eps.length,
              itemBuilder: (_, i) => ListTile(
                leading: CircleAvatar(child: Text('${eps[i].number}')),
                title: Text(eps[i].title),
                subtitle: eps[i].filler ? const Text('Filler') : null,
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => PlayerPage(anime: widget.anime, episode: eps[i]))),
              ),
            );
          },
        ),
      );
}

// ============================================================================
// Schedule / new episodes
// ============================================================================
class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});
  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  DateTime _day = DateTime.now();
  Future<List<ScheduleItem>>? _f;

  void _load() => _f = context.read<HiAnimeProvider>().schedule(_day);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => setState(_load));
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        SizedBox(
          height: 64,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: 7,
            itemBuilder: (_, i) {
              final d = DateTime.now().add(Duration(days: i));
              final sel = d.day == _day.day;
              return Padding(
                padding: const EdgeInsets.all(8),
                child: ChoiceChip(
                  label: Text(i == 0 ? 'Today' : '${d.month}/${d.day}'),
                  selected: sel,
                  onSelected: (_) => setState(() {
                    _day = d;
                    _load();
                  }),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: FutureBuilder<List<ScheduleItem>>(
            future: _f,
            builder: (_, s) {
              if (_f == null || s.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (s.hasError) return Center(child: Text('${s.error}'));
              final items = s.data!;
              if (items.isEmpty) return const Center(child: Text('Nothing scheduled'));
              return ListView.builder(
                itemCount: items.length,
                itemBuilder: (_, i) => ListTile(
                  leading: Text(items[i].time),
                  title: Text(items[i].anime.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(items[i].episodeLabel),
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => DetailPage(anime: items[i].anime))),
                ),
              );
            },
          ),
        ),
      ]);
}

// ============================================================================
// Offline downloads
// ============================================================================
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final list = context.watch<AppState>().downloads;
    if (list.isEmpty) return const Center(child: Text('No offline episodes'));
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (_, i) => ListTile(
        title: Text(list[i]['title'] ?? ''),
        subtitle: Text('Episode ${list[i]['episode']}'),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: () => context.read<AppState>().removeDownload(i),
        ),
        onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => LocalPlayerPage(entry: list[i]))),
      ),
    );
  }
}

class LocalPlayerPage extends StatefulWidget {
  const LocalPlayerPage({super.key, required this.entry});
  final Map entry;
  @override
  State<LocalPlayerPage> createState() => _LocalPlayerPageState();
}

class _LocalPlayerPageState extends State<LocalPlayerPage> {
  late final player = Player();
  late final controller = VideoController(player);
  @override
  void initState() {
    super.initState();
    player.open(Media('file://${widget.entry['path']}'));
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(backgroundColor: Colors.black, body: Video(controller: controller));
}

// ============================================================================
// Player (progress, Discord RPC, AniList sync)
// ============================================================================
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.anime, required this.episode, this.resumeMs = 0});
  final Anime anime;
  final Episode episode;
  final int resumeMs;
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final player = Player();
  late final controller = VideoController(player);
  late final AppState _state = context.read<AppState>();
  late final DiscordRpcService _discord = context.read<DiscordRpcService>();
  late final HiAnimeProvider _provider = context.read<HiAnimeProvider>();

  final _subs = <StreamSubscription>[];
  String? _error;
  String _server = '';
  bool _synced = false;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await _provider.extractStream(widget.episode.id);
      _server = s.server;
      await player.open(Media(s.sources.first.url, httpHeaders: s.headers), play: true);
      if (widget.resumeMs > 0) {
        await player.stream.duration.firstWhere((d) => d > Duration.zero);
        await player.seek(Duration(milliseconds: widget.resumeMs));
      }
      if (s.subtitles.isNotEmpty) {
        final t = s.subtitles.firstWhere((x) => x.isDefault || x.label.toLowerCase().contains('english'),
            orElse: () => s.subtitles.first);
        await player.setSubtitleTrack(SubtitleTrack.uri(t.url, title: t.label));
      }
      _subs.add(player.stream.playing.listen((_) => _pushRpc()));
      _subs.add(player.stream.position.listen(_onPosition));
      _pushRpc();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _pushRpc() {
    _discord.setWatching(MediaActivity(
      title: widget.anime.title,
      episode: widget.episode.number,
      coverUrl: widget.anime.cover,
      position: player.state.position,
      duration: player.state.duration,
      playing: player.state.playing,
    ));
  }

  void _onPosition(Duration pos) {
    final dur = player.state.duration;
    if (dur == Duration.zero) return;
    if (DateTime.now().difference(_lastSave).inSeconds >= 10) {
      _lastSave = DateTime.now();
      _state.saveProgress(widget.anime, widget.episode, pos.inMilliseconds, dur.inMilliseconds);
    }
    if (!_synced && pos.inMilliseconds / dur.inMilliseconds >= 0.85) {
      _synced = true;
      final token = _state.aniListToken;
      if (token != null) {
        AniListService.syncProgress(token, widget.anime.title, widget.episode.number)
            .catchError((_) {});
      }
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _discord.clearActivity();
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: Text('${widget.anime.title} • Ep ${widget.episode.number}',
              maxLines: 1, style: const TextStyle(fontSize: 14)),
          actions: [if (_server.isNotEmpty) Center(child: Padding(
              padding: const EdgeInsets.only(right: 12), child: Text(_server)))],
        ),
        body: _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
            : Video(controller: controller),
      );
}

// ============================================================================
// Settings
// ============================================================================
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static const _palette = <Color>[
    Color(0xFF0E0E14), Color(0xFF000000), Color(0xFF14110F), Color(0xFF0B1220),
    Color(0xFF1A0F1F), Color(0xFF0F1A14), Color(0xFF1F1A12), Color(0xFF1B1B1B),
  ];

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ListView(padding: const EdgeInsets.all(16), children: [
      const _Header('Appearance'),
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (final c in _palette)
          GestureDetector(
            onTap: () => app.setBackground(c),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                    color: app.background == c ? Colors.pinkAccent : Colors.white24, width: 2),
              ),
            ),
          ),
      ]),
      const SizedBox(height: 24),
      const _Header('Trackers'),
      ListTile(
        leading: const Icon(Icons.link),
        title: const Text('AniList'),
        subtitle: Text(app.aniListToken == null ? 'Not connected' : 'Connected'),
        trailing: app.aniListToken == null
            ? FilledButton(
                onPressed: () async {
                  try {
                    app.setAniListToken(await AniListService.login());
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                    }
                  }
                },
                child: const Text('Login'))
            : TextButton(onPressed: () => app.setAniListToken(null), child: const Text('Logout')),
      ),
      const ListTile(
        leading: Icon(Icons.link),
        title: Text('MyAnimeList'),
        subtitle: Text('Not included in this build'),
      ),
      const SizedBox(height: 24),
      const _Header('Providers'),
      const _ProviderSettings(),
      const SizedBox(height: 24),
      const _Header('Discord Rich Presence'),
      const _DiscordSettings(),
    ]);
  }
}

class _Header extends StatelessWidget {
  const _Header(this.t);
  final String t;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.pinkAccent)),
      );
}

class _ProviderSettings extends StatelessWidget {
  const _ProviderSettings();
  @override
  Widget build(BuildContext context) {
    final box = context.read<AppState>().box;
    final p = context.read<HiAnimeProvider>();
    return Column(children: [
      TextFormField(
        initialValue: p.baseUrl,
        decoration: const InputDecoration(labelText: 'HiAnime base URL'),
        onChanged: (v) {
          p.baseUrl = v.trim();
          box.put('hianimeUrl', p.baseUrl);
        },
      ),
      TextFormField(
        initialValue: box.get('megacloudKeyUrl') ?? '',
        decoration: const InputDecoration(labelText: 'MegaCloud key URL (optional)'),
        onChanged: (v) {
          p.megacloudKeyUrl = v.trim();
          box.put('megacloudKeyUrl', v.trim());
        },
      ),
    ]);
  }
}

class _DiscordSettings extends StatefulWidget {
  const _DiscordSettings();
  @override
  State<_DiscordSettings> createState() => _DiscordSettingsState();
}

class _DiscordSettingsState extends State<_DiscordSettings> {
  late DiscordRpcConfig c = context.read<DiscordRpcService>().config;

  void _save() {
    context.read<AppState>().box.put('discord', c.toMap());
    context.read<DiscordRpcService>().updateConfig(c);
    setState(() {});
  }

  Widget _field(String label, String value, void Function(String) on,
          {bool obscure = false}) =>
      TextFormField(
        initialValue: value,
        obscureText: obscure,
        decoration: InputDecoration(labelText: label),
        onFieldSubmitted: (v) {
          on(v.trim());
          _save();
        },
        onTapOutside: (_) => FocusScope.of(context).unfocus(),
      );

  @override
  Widget build(BuildContext context) {
    final status = context.watch<DiscordRpcService>().status;
    return Column(children: [
      SwitchListTile(
          title: const Text('Enable Rich Presence'),
          subtitle: Text('Status: ${status.name}'),
          value: c.enabled,
          onChanged: (v) {
            c.enabled = v;
            _save();
          }),
      _field('Discord user token', c.token, (v) => c.token = v, obscure: true),
      _field('Application ID', c.applicationId, (v) => c.applicationId = v),
      SwitchListTile(title: const Text('Show title'), value: c.showTitle,
          onChanged: (v) { c.showTitle = v; _save(); }),
      SwitchListTile(title: const Text('Show episode'), value: c.showEpisode,
          onChanged: (v) { c.showEpisode = v; _save(); }),
      SwitchListTile(title: const Text('Show timestamp'), value: c.showTimestamp,
          onChanged: (v) { c.showTimestamp = v; _save(); }),
      SwitchListTile(title: const Text('Show cover art'), value: c.showCoverArt,
          onChanged: (v) { c.showCoverArt = v; _save(); }),
      _field('Custom status ({title}, {episode})', c.customStatus, (v) => c.customStatus = v),
      _field('Button 1 label', c.button1Label, (v) => c.button1Label = v),
      _field('Button 1 URL', c.button1Url, (v) => c.button1Url = v),
      _field('Button 2 label', c.button2Label, (v) => c.button2Label = v),
      _field('Button 2 URL', c.button2Url, (v) => c.button2Url = v),
    ]);
  }
}
