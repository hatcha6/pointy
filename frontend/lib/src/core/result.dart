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
