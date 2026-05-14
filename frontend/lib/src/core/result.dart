sealed class Result<T> {
  const Result();
}

class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;
}

class Error<T> extends Result<T> {
  const Error(this.exception);

  final Exception exception;
}
