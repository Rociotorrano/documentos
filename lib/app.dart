import 'package:flutter/material.dart';

import 'core/auth/auth_controller.dart';
import 'core/theme/app_theme.dart';
import 'features/carpetas/presentation/carpetas_screen.dart';
import 'features/login/presentation/login_screen.dart';

class GisDocumentsApp extends StatelessWidget {
  const GisDocumentsApp({super.key, required this.authController});

  final AuthController authController;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GIS Documentación',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: AnimatedBuilder(
        animation: authController,
        builder: (context, _) => switch (authController.status) {
          AuthStatus.initializing => const _StartupScreen(),
          AuthStatus.unauthenticated => LoginScreen(
            authController: authController,
          ),
          AuthStatus.authenticated => CarpetasScreen(
            authController: authController,
          ),
        },
      ),
    );
  }
}

class _StartupScreen extends StatelessWidget {
  const _StartupScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.folder_copy_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
            const SizedBox(height: 22),
            const SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 14),
            Text(
              'Preparando gestión documental',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
