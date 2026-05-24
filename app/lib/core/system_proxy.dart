import 'dart:io';

class SystemProxyConfig {
  const SystemProxyConfig({
    this.httpProxy,
    this.httpsProxy,
    this.allProxy,
    this.noProxy,
  });

  final String? httpProxy;
  final String? httpsProxy;
  final String? allProxy;
  final String? noProxy;

  bool get hasProxy =>
      _hasValue(httpProxy) || _hasValue(httpsProxy) || _hasValue(allProxy);

  Map<String, String> toEnvironment() {
    final env = <String, String>{};
    _addProxyPair(env, 'HTTP_PROXY', 'http_proxy', httpProxy);
    _addProxyPair(env, 'HTTPS_PROXY', 'https_proxy', httpsProxy);
    _addProxyPair(env, 'ALL_PROXY', 'all_proxy', allProxy);
    _addProxyPair(env, 'NO_PROXY', 'no_proxy', noProxy);
    return env;
  }

  static SystemProxyConfig? readCurrent() {
    if (!Platform.isWindows) return null;
    final result = Process.runSync('reg', const [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
    ], runInShell: false);
    if (result.exitCode != 0) return null;
    return fromWindowsRegistryOutput('${result.stdout}');
  }

  static SystemProxyConfig? fromWindowsRegistryOutput(String output) {
    final values = <String, String>{};
    final pattern = RegExp(
      r'^\s*(ProxyEnable|ProxyServer|ProxyOverride)\s+REG_\w+\s+(.*)$',
      caseSensitive: false,
    );
    for (final line in output.split(RegExp(r'\r?\n'))) {
      final match = pattern.firstMatch(line);
      if (match == null) continue;
      values[match.group(1)!.toLowerCase()] = match.group(2)!.trim();
    }
    return fromWindowsRegistryValues(values);
  }

  static SystemProxyConfig? fromWindowsRegistryValues(
    Map<String, String> values,
  ) {
    final normalized = <String, String>{
      for (final entry in values.entries)
        entry.key.toLowerCase(): entry.value.trim(),
    };
    if (!_windowsProxyEnabled(normalized['proxyenable'])) return null;
    final server = normalized['proxyserver'];
    if (!_hasValue(server)) return null;

    final parsed = _parseWindowsProxyServer(server!);
    final httpProxy = parsed['http'];
    final httpsProxy = parsed['https'] ?? httpProxy;
    final allProxy = parsed['all'];
    final noProxy = _parseWindowsProxyOverride(normalized['proxyoverride']);
    final config = SystemProxyConfig(
      httpProxy: httpProxy,
      httpsProxy: httpsProxy,
      allProxy: allProxy,
      noProxy: noProxy,
    );
    return config.hasProxy ? config : null;
  }

  static Map<String, String> _parseWindowsProxyServer(String value) {
    final result = <String, String>{};
    final trimmed = value.trim();
    if (!trimmed.contains('=')) {
      final proxy = _normalizeProxyUrl(trimmed, defaultScheme: 'http');
      result['http'] = proxy;
      result['https'] = proxy;
      return result;
    }

    for (final rawPart in trimmed.split(';')) {
      final part = rawPart.trim();
      if (part.isEmpty) continue;
      final equals = part.indexOf('=');
      if (equals <= 0 || equals == part.length - 1) continue;
      final key = part.substring(0, equals).trim().toLowerCase();
      final proxy = part.substring(equals + 1).trim();
      if (!_hasValue(proxy)) continue;
      switch (key) {
        case 'http':
          result['http'] = _normalizeProxyUrl(proxy, defaultScheme: 'http');
        case 'https':
          result['https'] = _normalizeProxyUrl(proxy, defaultScheme: 'http');
        case 'socks':
          result['all'] = _normalizeProxyUrl(proxy, defaultScheme: 'socks5');
      }
    }
    return result;
  }

  static String? _parseWindowsProxyOverride(String? value) {
    if (!_hasValue(value)) return null;
    final parts = <String>[];
    for (final rawPart in value!.split(';')) {
      final part = rawPart.trim();
      if (part.isEmpty) continue;
      if (part.toLowerCase() == '<local>') {
        parts.addAll(const ['localhost', '127.0.0.1', '::1']);
      } else {
        parts.add(part);
      }
    }
    return _mergeList(parts);
  }

  static String _normalizeProxyUrl(
    String value, {
    required String defaultScheme,
  }) {
    final trimmed = value.trim();
    if (trimmed.contains('://')) return trimmed;
    return '$defaultScheme://$trimmed';
  }

  static bool _windowsProxyEnabled(String? value) {
    if (!_hasValue(value)) return false;
    final normalized = value!.trim().toLowerCase();
    return normalized == '1' ||
        normalized == '0x1' ||
        normalized.endsWith('(1)');
  }

  static void _addProxyPair(
    Map<String, String> env,
    String upper,
    String lower,
    String? value,
  ) {
    if (!_hasValue(value)) return;
    env[upper] = value!.trim();
    env[lower] = value.trim();
  }
}

String mergeNoProxyEntries(Iterable<String?> values) {
  final parts = <String>[];
  for (final value in values) {
    if (!_hasValue(value)) continue;
    parts.addAll(value!.split(',').map((part) => part.trim()));
  }
  return _mergeList(parts) ?? '';
}

String? proxyEnvironmentValue(Map<String, String> env, Iterable<String> keys) {
  for (final key in keys) {
    final value = env[key];
    if (_hasValue(value)) return value!.trim();
  }
  final wanted = keys.map((key) => key.toLowerCase()).toSet();
  for (final entry in env.entries) {
    if (wanted.contains(entry.key.toLowerCase()) && _hasValue(entry.value)) {
      return entry.value.trim();
    }
  }
  return null;
}

String? _mergeList(Iterable<String> parts) {
  final seen = <String>{};
  final merged = <String>[];
  for (final part in parts) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    final key = trimmed.toLowerCase();
    if (seen.add(key)) merged.add(trimmed);
  }
  if (merged.isEmpty) return null;
  return merged.join(',');
}

bool _hasValue(String? value) => value != null && value.trim().isNotEmpty;
