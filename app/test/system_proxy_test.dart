import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/core/system_proxy.dart';

void main() {
  test('parses a shared Windows proxy server for HTTP and HTTPS', () {
    final config = SystemProxyConfig.fromWindowsRegistryValues({
      'ProxyEnable': '0x1',
      'ProxyServer': '127.0.0.1:7890',
      'ProxyOverride': '<local>;*.example.test',
    });

    expect(config, isNotNull);
    expect(config!.httpProxy, 'http://127.0.0.1:7890');
    expect(config.httpsProxy, 'http://127.0.0.1:7890');
    expect(config.noProxy, 'localhost,127.0.0.1,::1,*.example.test');
    expect(config.toEnvironment()['HTTPS_PROXY'], 'http://127.0.0.1:7890');
    expect(config.toEnvironment()['https_proxy'], 'http://127.0.0.1:7890');
  });

  test('parses protocol-specific Windows proxy servers', () {
    final config = SystemProxyConfig.fromWindowsRegistryValues({
      'ProxyEnable': '1',
      'ProxyServer':
          'http=proxy.internal:8080;https=secure.internal:8443;socks=127.0.0.1:1080',
    });

    expect(config, isNotNull);
    expect(config!.httpProxy, 'http://proxy.internal:8080');
    expect(config.httpsProxy, 'http://secure.internal:8443');
    expect(config.allProxy, 'socks5://127.0.0.1:1080');
  });

  test('ignores disabled Windows proxy settings', () {
    final config = SystemProxyConfig.fromWindowsRegistryValues({
      'ProxyEnable': '0x0',
      'ProxyServer': '127.0.0.1:7890',
    });

    expect(config, isNull);
  });

  test('merges no proxy entries without duplicates', () {
    expect(
      mergeNoProxyEntries([
        'localhost,127.0.0.1',
        'LOCALHOST',
        '::1',
        '*.example.test',
      ]),
      'localhost,127.0.0.1,::1,*.example.test',
    );
  });
}
