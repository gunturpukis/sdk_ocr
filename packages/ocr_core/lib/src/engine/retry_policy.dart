class RetryPolicy {
  final int maxAttempts;
  final Duration initialDelay;
  final int backoffMultiplier;

  const RetryPolicy({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(seconds: 1),
    this.backoffMultiplier = 2,
  });

  Future<T> execute<T>(
    Future<T> Function() action, {
    bool Function(Object error)? retryIf,
    void Function(int attempt, int maxAttempts)? onRetry,
  }) async {
    var attempt = 0;
    var delay = initialDelay;

    while (true) {
      attempt++;
      try {
        return await action();
      } catch (e) {
        final shouldRetry = attempt < maxAttempts && (retryIf?.call(e) ?? true);
        if (!shouldRetry) rethrow;

        onRetry?.call(attempt + 1, maxAttempts);
        await Future.delayed(delay);
        delay = delay * backoffMultiplier;
      }
    }
  }
}
