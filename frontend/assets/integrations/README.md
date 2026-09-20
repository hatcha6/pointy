# Provider logos

One file per provider, named for its **backend key**: `hdbox.png`, `lnet.png`,
`qareeb.png`. Third-party brand marks are usually drawn for a light background,
so `IntegrationProviderLogo` renders them on a white chip in both themes rather
than tinting them.

A missing file is not an error: the widget falls back to a themed icon, which is
also what an unrecognised provider gets. Add the file here **and** list it under
`assets:` in `pubspec.yaml` — Flutter only bundles what is declared.
