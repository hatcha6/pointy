/// What the machine underneath is: two maps, ready to be merged into an event.
typedef AnalyticsHostFacts = ({
  Map<String, Object?> attributes,
  Map<String, num> metrics,
});

/// The web build's answer, which is that it does not know.
///
/// A browser has no operating system version, no processor count and no memory
/// figure to give. Absent fields are the honest reply; a profile assembled out
/// of the user agent would be a guess dressed as a measurement, and it would
/// contaminate every fleet average taken over the real tills.
Future<AnalyticsHostFacts> readHostFacts() async => (
  attributes: const <String, Object?>{},
  metrics: const <String, num>{},
);
