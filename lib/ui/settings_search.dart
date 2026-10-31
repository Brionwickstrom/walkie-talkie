// v2.6.2: search for a setting, then jump to it. The matching is a pure
// function over `settingsIndex`; the widgets here draw the search box, the
// results and the brief highlight on the setting that was picked.
import 'package:flutter/material.dart';

import 'settings_index.dart';

/// Lower case, no apostrophes or hyphens ("Who's" -> "whos", "Wi-Fi" ->
/// "wifi"), any other punctuation becomes a space.
String normalizeSearch(String s) => s
    .toLowerCase()
    .replaceAll(RegExp("['\u2019\\-]"), '')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();

/// "relays" -> "relay", "batteries" -> "batteri" (only used to compare).
String _stem(String w) {
  if (w.length > 4 && w.endsWith('ies')) return w.substring(0, w.length - 3);
  if (w.length > 3 && w.endsWith('es')) return w.substring(0, w.length - 2);
  if (w.length > 3 && w.endsWith('s')) return w.substring(0, w.length - 1);
  return w;
}

class _Hay {
  _Hay(SettingEntry e)
    : title = normalizeSearch('${e.title} ${e.label}'),
      words = normalizeSearch(e.words.join(' ')),
      wordList = e.words.map(normalizeSearch).toList(),
      section = normalizeSearch(e.section),
      about = normalizeSearch(e.about);
  final String title;
  final String words;
  final List<String> wordList;
  final String section;
  final String about;

  bool startsAWord(String hay, String w) =>
      hay.startsWith(w) || hay.contains(' $w');

  int score(String w) {
    final v = {w, _stem(w)};
    var best = 0;
    for (final x in v) {
      if (x.isEmpty) continue;
      var s = 0;
      if (startsAWord(title, x)) {
        s = 8;
      } else if (title.contains(x)) {
        s = 5;
      }
      if (wordList.contains(x)) {
        s = s < 7 ? 7 : s;
      } else if (startsAWord(words, x)) {
        s = s < 6 ? 6 : s;
      } else if (x.length >= 3 && words.contains(x)) {
        s = s < 3 ? 3 : s;
      }
      if (s < 2 && section.contains(x)) s = 2;
      if (s < 1 && x.length >= 3 && about.contains(x)) s = 1;
      if (s > best) best = s;
    }
    return best;
  }
}

final Map<SettingEntry, _Hay> _hays = {};

/// The entries matching [query], best first. Every typed word has to match
/// something (title, a synonym, the heading or the description). Empty
/// query gives an empty list. [homes] limits where the settings live (the
/// Radio settings page only searches itself).
List<SettingEntry> searchSettings(
  String query, {
  Iterable<SettingEntry> entries = settingsIndex,
  SettingsEnv env = const SettingsEnv(),
  Set<SettingsHome>? homes,
}) {
  final words = normalizeSearch(query).split(' ').where((w) => w.isNotEmpty);
  if (words.isEmpty) return const [];
  final scored = <(SettingEntry, int, int)>[];
  var i = 0;
  for (final e in entries) {
    i++;
    if (homes != null && !homes.contains(e.home)) continue;
    if (!env.allows(e.needs)) continue;
    final h = _hays.putIfAbsent(e, () => _Hay(e));
    var total = 0;
    var ok = true;
    for (final w in words) {
      final s = h.score(w);
      if (s == 0) {
        ok = false;
        break;
      }
      total += s;
    }
    if (ok) scored.add((e, total, i));
  }
  scored.sort((a, b) {
    final c = b.$2.compareTo(a.$2);
    return c != 0 ? c : a.$3.compareTo(b.$3);
  });
  return [for (final s in scored) s.$1];
}

/// Owns the search text and scrolls to / highlights anchored settings.
class SettingsJump extends ChangeNotifier {
  final TextEditingController field = TextEditingController();
  final Map<String, _SettingAnchorState> _anchors = {};

  String get query => field.text;
  bool get searching => field.text.trim().isNotEmpty;

  void setQuery(String q) {
    if (field.text == q) return;
    field.text = q;
    notifyListeners();
  }

  void _changed() => notifyListeners();

  /// Scrolls to the setting with [id] and highlights it for a moment.
  /// False when it is not on screen.
  bool jumpTo(String id) {
    final a = _anchors[id];
    if (a == null || !a.mounted) return false;
    Scrollable.ensureVisible(
      a.context,
      alignment: 0.08,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
    a.flash();
    return true;
  }

  /// Ends the search (the whole page is back) and then jumps.
  void showAndJump(String id) {
    setQuery('');
    WidgetsBinding.instance.addPostFrameCallback((_) => jumpTo(id));
  }

  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }
}

class _JumpScope extends InheritedWidget {
  const _JumpScope({required this.jump, required super.child});
  final SettingsJump jump;

  @override
  bool updateShouldNotify(_JumpScope old) => old.jump != jump;
}

/// Marks a setting so the search can scroll to it and highlight it. Does
/// nothing when there is no search around it. [id] must match an entry in
/// `settingsIndex`.
class SettingAnchor extends StatefulWidget {
  const SettingAnchor({super.key, required this.id, required this.child});
  final String id;
  final Widget child;

  @override
  State<SettingAnchor> createState() => _SettingAnchorState();
}

class _SettingAnchorState extends State<SettingAnchor>
    with SingleTickerProviderStateMixin {
  SettingsJump? _jump;
  AnimationController? _flash;

  /// 0 -> 1 -> hold -> 0 over the animation.
  static double _level(double t) {
    if (t < 0.12) return t / 0.12;
    if (t < 0.65) return 1;
    return (1 - t) / 0.35;
  }

  void flash() {
    final c = _flash ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    setState(() {});
    c.forward(from: 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final j = context.getInheritedWidgetOfExactType<_JumpScope>()?.jump;
    if (j != _jump) {
      _jump?._anchors.remove(widget.id);
      _jump = j;
      j?._anchors[widget.id] = this;
    }
  }

  @override
  void didUpdateWidget(SettingAnchor old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) {
      _jump?._anchors.remove(old.id);
      _jump?._anchors[widget.id] = this;
    }
  }

  @override
  void dispose() {
    if (_jump?._anchors[widget.id] == this) _jump?._anchors.remove(widget.id);
    _flash?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = _flash;
    if (f == null) return widget.child;
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: f,
      child: widget.child,
      builder: (context, child) {
        final v = f.isAnimating ? _level(f.value) : 0.0;
        return DecoratedBox(
          key: const Key('setting-highlight'),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.20 * v),
            borderRadius: BorderRadius.circular(8),
          ),
          child: child,
        );
      },
    );
  }
}

/// What a tapped result does besides jumping on the same page.
class SettingsSearchActions {
  const SettingsSearchActions({this.openRadio, this.openTrip});

  /// Open the Radio settings page, scrolled to this setting id.
  final void Function(String id)? openRadio;

  /// Show the Trip map's Range test page for this setting id.
  final void Function(String id)? openTrip;
}

/// A search box above [body]; while something is typed, the matching
/// settings replace [body] (which stays alive, so nothing typed in it is
/// lost). Tapping a result goes to the setting.
class SettingsSearchLayout extends StatefulWidget {
  const SettingsSearchLayout({
    super.key,
    required this.body,
    this.env = const SettingsEnv(),
    this.homes,
    this.actions = const SettingsSearchActions(),
    this.padding = EdgeInsets.zero,
    this.bottomGap = 0,
    this.initialJump,
    this.fillWhileSearching = false,
  });

  final Widget body;
  final SettingsEnv env;

  /// Only these places are searched (null = all).
  final Set<SettingsHome>? homes;
  final SettingsSearchActions actions;
  final EdgeInsets padding;
  final double bottomGap;

  /// While searching, fill the height the parent allows, so a sheet does
  /// not shrink (and the search box does not jump) as the list gets shorter.
  final bool fillWhileSearching;

  /// Scroll to this setting after the first frame (opened from a search).
  final String? initialJump;

  @override
  State<SettingsSearchLayout> createState() => _SettingsSearchLayoutState();
}

class _SettingsSearchLayoutState extends State<SettingsSearchLayout> {
  final SettingsJump _jump = SettingsJump();

  @override
  void initState() {
    super.initState();
    _jump.field.addListener(_jump._changed);
    final id = widget.initialJump;
    if (id != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jump.jumpTo(id));
    }
  }

  @override
  void dispose() {
    _jump.field.removeListener(_jump._changed);
    _jump.dispose();
    super.dispose();
  }

  void _open(SettingEntry e) {
    FocusManager.instance.primaryFocus?.unfocus();
    switch (e.home) {
      case SettingsHome.settings:
        _jump.showAndJump(e.id);
      case SettingsHome.radio:
        if (widget.actions.openRadio != null) {
          widget.actions.openRadio!(e.id);
        } else {
          _jump.showAndJump(e.id);
        }
      case SettingsHome.trip:
        widget.actions.openTrip?.call(e.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _JumpScope(
      jump: _jump,
      child: ListenableBuilder(
        listenable: _jump,
        builder: (context, _) {
          final searching = _jump.searching;
          final hits = searching
              ? searchSettings(
                  _jump.query,
                  env: widget.env,
                  homes: widget.homes,
                )
              : const <SettingEntry>[];
          return Padding(
            padding: widget.padding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SearchField(jump: _jump),
                Flexible(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final fill =
                          searching &&
                          widget.fillWhileSearching &&
                          box.maxHeight.isFinite;
                      return SingleChildScrollView(
                        key: const Key('settings-scroll'),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: fill ? box.maxHeight : 0,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (searching)
                                _Results(
                                  hits: hits,
                                  env: widget.env,
                                  onOpen: _open,
                                ),
                              Offstage(offstage: searching, child: widget.body),
                              SizedBox(height: widget.bottomGap),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.jump});
  final SettingsJump jump;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: const Key('settings-search'),
        controller: jump.field,
        textInputAction: TextInputAction.search,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          hintText: 'Search settings',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: jump.searching
              ? IconButton(
                  key: const Key('settings-search-clear'),
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close),
                  onPressed: () => jump.setQuery(''),
                )
              : null,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
        ),
      ),
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({required this.hits, required this.env, required this.onOpen});
  final List<SettingEntry> hits;
  final SettingsEnv env;
  final void Function(SettingEntry) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (hits.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 16),
        child: Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'No matching settings',
                key: const Key('settings-search-empty'),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                'Try a shorter or different word, for example battery, '
                'relay, weather, radio, precision or quiet.',
                key: const Key('settings-search-hint'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              hits.length == 1
                  ? '1 matching setting'
                  : '${hits.length} matching settings',
              key: const Key('settings-search-count'),
              style: theme.textTheme.labelMedium,
            ),
          ),
        ),
        for (final e in hits) _ResultTile(entry: e, env: env, onOpen: onOpen),
      ],
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.entry,
    required this.env,
    required this.onOpen,
  });
  final SettingEntry entry;
  final SettingsEnv env;
  final void Function(SettingEntry) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final needsRadio = entry.home == SettingsHome.radio && !env.radioReady;
    return ListTile(
      key: Key('search-result-${entry.id}'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(switch (entry.home) {
        SettingsHome.settings => Icons.settings_outlined,
        SettingsHome.radio => Icons.settings_input_antenna,
        SettingsHome.trip => Icons.terrain,
      }),
      title: Text(entry.title, maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.path,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: cs.primary),
          ),
          Text(entry.about, maxLines: 3, overflow: TextOverflow.ellipsis),
          if (needsRadio)
            Text(
              'Connect your radio first to change it.',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
            ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => onOpen(entry),
    );
  }
}
