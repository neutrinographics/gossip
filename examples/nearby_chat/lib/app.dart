import 'package:flutter/material.dart';

import 'presentation/presentation.dart';

class ChatApp extends StatefulWidget {
  final ChatController controller;

  const ChatApp({super.key, required this.controller});

  @override
  State<ChatApp> createState() => _ChatAppState();
}

class _ChatAppState extends State<ChatApp> {
  final _themeController = ThemeController();

  @override
  void dispose() {
    _themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _themeController,
      builder: (context, _) {
        return MaterialApp(
          title: 'Nearby Chat',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: _themeController.themeMode,
          home: ChannelListScreen(
            controller: widget.controller,
            themeController: _themeController,
          ),
        );
      },
    );
  }
}
