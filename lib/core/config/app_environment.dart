class AppEnvironment {
  AppEnvironment._();

  static late final String baseUrl;
  static String defaultCurrency = 'ر.ي';
  static String signalRHubUrl = '';
  static bool _isConfigured = false;

  static bool get isConfigured => _isConfigured;
  static void configure({
    required String baseUrl,
    String signalRHubUrl = '',
  }) {
    AppEnvironment.baseUrl = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    AppEnvironment.signalRHubUrl = signalRHubUrl.isEmpty
        ? _defaultSignalRHubUrl(AppEnvironment.baseUrl)
        : signalRHubUrl;
    _isConfigured = true;
  }

  static String _defaultSignalRHubUrl(String apiBaseUrl) {
    // The API controllers are under /api, while the actual Hub is mapped at
    // the host root (/hubs/tracking).
    final root = apiBaseUrl.replaceFirst(
      RegExp(r'/api(?:/v[0-9]+)?/?$', caseSensitive: false),
      '',
    );
    return '$root/hubs/tracking';
  }
}
