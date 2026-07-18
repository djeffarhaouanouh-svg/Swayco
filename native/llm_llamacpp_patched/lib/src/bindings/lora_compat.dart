// SWAYCO PATCH — LoRA API compatibility shim.
//
// The iOS/Android native libs are built from Tencent's STQ fork
// (sjl623/llama.cpp @ STQ_0, PR #22836) so the 1.25-bit Hy-MT2 model's STQ1_0
// ternary kernel is available. That fork tracks a much newer llama.cpp than the
// bindings were originally generated against, and upstream replaced the three
// single-adapter LoRA entry points with one batch call:
//
//     llama_set_adapter_lora(ctx, adapter, scale)   ->  gone
//     llama_rm_adapter_lora(ctx, adapter)           ->  gone
//     llama_clear_adapter_lora(ctx)                 ->  gone
//     llama_set_adapters_lora(ctx, adapters**, n, scales*)   <- the replacement
//
// Regenerating the bindings against the fork's headers (which is what fixes the
// struct-layout mismatch that was segfaulting the app on first inference) drops
// the old three. This extension puts them back, implemented on top of the new
// batch call, so the plugin's existing call sites keep working unchanged.
//
// Swayco itself never uses LoRA — the on-device translator loads a plain GGUF —
// so this exists to keep the vendored plugin compiling and behaviourally close,
// not because we exercise it.
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:llm_llamacpp/src/bindings/llama_bindings.dart';

extension LlamaLoraCompat on LlamaBindings {
  /// Set a SINGLE LoRA adapter on [ctx], as the removed
  /// `llama_set_adapter_lora` did.
  ///
  /// NOTE the semantic difference inherited from upstream: the new call
  /// *replaces* the context's adapter set rather than adding to it, so applying
  /// two adapters one after the other no longer stacks them — the second call
  /// wins. Pass them together via [llama_set_adapters_lora] if you need both.
  int llama_set_adapter_lora(
    Pointer<llama_context> ctx,
    Pointer<llama_adapter_lora> adapter,
    double scale,
  ) {
    final adapters = calloc<Pointer<llama_adapter_lora>>();
    final scales = calloc<Float>();
    try {
      adapters[0] = adapter;
      scales[0] = scale;
      return llama_set_adapters_lora(ctx, adapters, 1, scales);
    } finally {
      calloc.free(adapters);
      calloc.free(scales);
    }
  }

  /// Remove all LoRA adapters from [ctx], as `llama_clear_adapter_lora` did.
  void llama_clear_adapter_lora(Pointer<llama_context> ctx) {
    llama_set_adapters_lora(ctx, nullptr, 0, nullptr);
  }

  /// Stand-in for the removed `llama_rm_adapter_lora`.
  ///
  /// Upstream has no per-adapter removal any more — the only way to drop one is
  /// to re-set the whole list without it, and the context does not expose what
  /// it currently holds. We therefore clear ALL adapters, which is correct for
  /// the single-adapter case and over-broad otherwise. Returns 0 (success) to
  /// match the old signature.
  int llama_rm_adapter_lora(
    Pointer<llama_context> ctx,
    Pointer<llama_adapter_lora> adapter,
  ) {
    llama_clear_adapter_lora(ctx);
    return 0;
  }
}
