/// The outcome of a call that can fail: a value, or the exception that
/// stopped it. Repositories answer with these so screens never catch.
sealed class Result<T> {
  const Result();

  static Future<Result<T>> guard<T>(Future<T> Function() operation) async {
    try {
      return Ok(await operation());
    } on Exception catch (exception) {
      return Error(exception);
    }
  }
}

class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;
}

class Error<T> extends Result<T> {
  const Error(this.exception);

  final Exception exception;
}
