/// Lets a search box hand the keyboard to the first catalog result.
///
/// The search field and the results grid are siblings, so neither can reach
/// the other's focus nodes; the grid registers itself here
/// ([CatalogResultsKeyboardRegion]) and the search box calls [focusFirst] on
/// ↓. A plain object, owned by the screen's view model like its other focus
/// requests.
class CatalogResultsFocus {
  bool Function()? _focusFirst;

  /// Focuses the first result. False when there is none on screen, so the
  /// caller can fall back to ordinary directional focus.
  bool focusFirst() => _focusFirst?.call() ?? false;

  void attach(bool Function() focusFirst) => _focusFirst = focusFirst;

  void detach(bool Function() focusFirst) {
    if (identical(_focusFirst, focusFirst)) {
      _focusFirst = null;
    }
  }
}
