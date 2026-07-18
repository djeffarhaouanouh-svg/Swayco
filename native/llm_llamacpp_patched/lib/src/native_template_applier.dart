part of 'persistent_inference_isolate.dart';

String _applyNativeChatTemplate(
  LlamaBindings bindings,
  ffi.Pointer<llama_model> model,
  List<IsolateMessage> messages,
) {
  final chatMessages = calloc<llama_chat_message>(messages.length);
  final allocatedPointers = <ffi.Pointer<Utf8>>[];

  // SWAYCO PATCH: pass the MODEL'S OWN template.
  //
  // llama_chat_apply_template's first parameter is the template STRING. Older
  // llama.cpp took a `llama_model *` there, where NULL meant "use the model's
  // template", so the upstream code passes nullptr — but the model parameter is
  // long gone, and nullptr now just falls back to a built-in default (ChatML).
  // The `model` argument this function receives was never used.
  //
  // For a model with a custom template that is silently fatal: Hy-MT2 wraps
  // turns in <｜hy_begin▁of▁sentence｜> / <｜hy_place▁holder▁no▁3｜>, so fed
  // ChatML it never sees a question and free-associates instead of translating
  // ("Bonjour, tu vas bien ?" -> "ボンジュール・トゥルー・トゥルー…"). Verified
  // locally with llama-completion: identical prompt and sampling, --jinja gives
  // "こんにちは、元気ですか？" and no template gives that garbage.
  final tmpl = bindings.llama_model_chat_template(model, ffi.nullptr);

  try {
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final rolePtr = msg.role.toNativeUtf8();
      final contentPtr = msg.content.toNativeUtf8();
      allocatedPointers.add(rolePtr);
      allocatedPointers.add(contentPtr);

      chatMessages[i].role = rolePtr.cast();
      chatMessages[i].content = contentPtr.cast();
    }

    final requiredSize = bindings.llama_chat_apply_template(
      tmpl,
      chatMessages,
      messages.length,
      true,
      ffi.nullptr,
      0,
    );

    if (requiredSize <= 0) {
      return _fallbackFormatMessages(messages);
    }

    final buffer = calloc<ffi.Char>(requiredSize + 1);
    try {
      final actualSize = bindings.llama_chat_apply_template(
        tmpl,
        chatMessages,
        messages.length,
        true,
        buffer,
        requiredSize + 1,
      );

      if (actualSize <= 0) {
        return _fallbackFormatMessages(messages);
      }

      return buffer.cast<Utf8>().toDartString(length: actualSize);
    } finally {
      calloc.free(buffer);
    }
  } finally {
    for (final ptr in allocatedPointers) {
      calloc.free(ptr);
    }
    calloc.free(chatMessages);
  }
}

String _fallbackFormatMessages(List<IsolateMessage> messages) {
  final buffer = StringBuffer();
  for (final msg in messages) {
    buffer.writeln('<|im_start|>${msg.role}');
    buffer.writeln(msg.content);
    buffer.writeln('<|im_end|>');
  }
  buffer.write('<|im_start|>assistant\n');
  return buffer.toString();
}
