import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'data/repositories/catalog_repository.dart';
import 'data/services/pos_api_service.dart';
import 'features/catalog/view_models/catalog_view_model.dart';
import 'features/catalog/views/catalog_screen.dart';
import 'features/pos/view_models/pos_view_model.dart';
import 'features/pos/views/pos_screen.dart';

class PointyApp extends StatelessWidget {
  const PointyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final catalogRepository = CatalogRepository(PosApiService());
    final posViewModel = PosViewModel(catalogRepository);

    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F7F9),
        useMaterial3: true,
      ),
      home: Builder(
        builder: (context) {
          return PosScreen(
            viewModel: posViewModel,
            onOpenCatalog: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CatalogScreen(
                    viewModel: CatalogViewModel(catalogRepository),
                    onOpenPos: () => Navigator.of(context).pop(),
                  ),
                ),
              );
              await posViewModel.loadCatalog();
            },
          );
        },
      ),
    );
  }
}
