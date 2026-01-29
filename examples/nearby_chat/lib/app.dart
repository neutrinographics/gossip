import 'package:flutter/material.dart';

import 'presentation/presentation.dart';

class ChatApp extends StatelessWidget {
  final ChatController controller;

  const ChatApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nearby Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: ChannelListScreen(controller: controller),
    );
  }
}
