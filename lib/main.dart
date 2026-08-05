import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://glpzohfzldvztseriwky.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdscHpvaGZ6bGR2enRzZXJpd2t5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ1Mjc2NDcsImV4cCI6MjEwMDEwMzY0N30.Pm5mXGAHvf7A-3FO1z4MIK8E-pj3YqAYenRUS64jPpA',
  );

  runApp(const ProviderScope(child: FieldLoopApp()));
}
