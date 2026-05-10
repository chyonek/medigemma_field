# Flutter / Dart
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

# flutter_gemma が依存する MediaPipe / Protobuf / LiteRT ネイティブクラス。
# minify を有効化したとき UnsatisfiedLinkError を防ぐために必須。
-keep class com.google.mediapipe.** { *; }
-dontwarn com.google.mediapipe.**

-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**

-keep class com.google.ai.edge.localagents.** { *; }
-dontwarn com.google.ai.edge.localagents.**

-keep class com.google.ai.edge.litert.** { *; }
-dontwarn com.google.ai.edge.litert.**

# image_picker / camera が裏で使う Java reflection 系
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**
