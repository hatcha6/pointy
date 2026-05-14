import 'package:flutter/material.dart';

import 'data/repositories/catalog_repository.dart';
import 'data/services/pos_api_service.dart';
import 'features/pos/view_models/pos_view_model.dart';
import 'features/pos/views/pos_screen.dart';

class PointyApp extends StatelessWidget {
  const PointyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final catalogRepository = CatalogRepository(PosApiService());

    return MaterialApp(
      title: 'Pointy POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F7F9),
        useMaterial3: true,
      ),
      home: PosScreen(viewModel: PosViewModel(catalogRepository)),
    );
  }
}
