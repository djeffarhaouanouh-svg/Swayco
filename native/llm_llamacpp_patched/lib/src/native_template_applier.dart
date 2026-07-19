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

  // SWAYCO PATCH #2: llama.cpp MIS-DETECTS Hy-MT2's template.
  //
  // llama_chat_apply_template does not run Jinja — it pattern-matches the
  // template string against a list of known families. In llama-chat.cpp the
  // HUNYUAN_VL arm is tested BEFORE HUNYUAN_DENSE and only asks whether the
  // template mentions <｜hy_Assistant｜> and <｜hy_begin▁of▁sentence｜>, which
  // Hy-MT2's does — so this hunyuan-DENSE model gets formatted as VL. The two
  // put the markers in opposite order:
  //
  //   DENSE (right): <｜hy_User｜>{content}<｜hy_Assistant｜>
  //   VL    (wrong): <｜hy_begin▁of▁sentence｜>{content}<｜hy_User｜>
  //
  // Formatted as VL the model never receives <｜hy_Assistant｜>, i.e. the cue
  // that it is its turn to answer, so it emits its BOS over and over instead of
  // translating — the endless <｜hy_begin▁of▁sentence｜> run we were seeing.
  //
  // Detect the dense template by a marker only IT carries in the Jinja source
  // and render it here. Verified against this exact GGUF with llama-completion:
  // "<｜hy_User｜>Translate … Bonjour, ça va ?<｜hy_Assistant｜>" returns
  // "こんにちは、元気ですか？".
  if (tmpl != ffi.nullptr) {
    final tmplStr = tmpl.cast<Utf8>().toDartString();
    if (tmplStr.contains('<｜hy_User｜>{{ message[\'content\'] }}')) {
      return _formatHunyuanDense(messages);
    }
  }

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

/// Render Tencent's hunyuan-dense chat format, mirroring llama.cpp's
/// LLM_CHAT_TEMPLATE_HUNYUAN_DENSE arm (see llama-chat.cpp) — which that
/// library's own detection never reaches for this model.
///
/// Emits the leading <｜hy_begin▁of▁sentence｜> (the model's BOS) itself, so the
/// caller tokenises this with add_special = false and the model sees exactly one.
String _formatHunyuanDense(List<IsolateMessage> messages) {
  final b = StringBuffer('<｜hy_begin▁of▁sentence｜>');
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    if (i == 0 && m.role == 'system') {
      b.write('${m.content}<｜hy_place▁holder▁no▁3｜>');
    } else if (m.role == 'assistant') {
      b.write('<｜hy_Assistant｜>${m.content}<｜hy_place▁holder▁no▁2｜>');
    } else if (m.role == 'user') {
      // The trailing <｜hy_Assistant｜> is the generation prompt: it tells the
      // model to answer. Without it Hy-MT2 just repeats its BOS.
      b.write('<｜hy_User｜>${m.content}<｜hy_Assistant｜>');
    }
  }
  return b.toString();
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
