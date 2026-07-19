part of 'persistent_inference_isolate.dart';

void _handleInferenceRequest(
  _InferenceRequestMessage request,
  SendPort mainSendPort,
  ffi.DynamicLibrary lib,
  LlamaBindings bindings,
) {
  ffi.Pointer<llama_adapter_lora>? loraAdapter;

  try {
    final modelParams = bindings.llama_model_default_params();
    modelParams.n_gpu_layers = request.nGpuLayers;

    final modelPathPtr = request.modelPath.toNativeUtf8();
    final model = bindings.llama_load_model_from_file(
      modelPathPtr.cast(),
      modelParams,
    );
    calloc.free(modelPathPtr);

    if (model.address == 0) {
      mainSendPort.send(
        _IsolateResponse(
          requestId: request.requestId,
          payload: InferenceError(
            'Failed to load model from ${request.modelPath}',
          ),
          isComplete: true,
        ),
      );
      return;
    }

    if (request.loraPath != null) {
      final loraPathPtr = request.loraPath!.toNativeUtf8();
      loraAdapter = bindings.llama_adapter_lora_init(model, loraPathPtr.cast());
      calloc.free(loraPathPtr);

      if (loraAdapter.address == 0) {
        bindings.llama_free_model(model);
        mainSendPort.send(
          _IsolateResponse(
            requestId: request.requestId,
            payload: InferenceError('Failed to load LoRA adapter'),
            isComplete: true,
          ),
        );
        return;
      }
    }

    final vocab = bindings.llama_model_get_vocab(model);
    final ctxParams = bindings.llama_context_default_params();
    ctxParams.n_ctx = request.contextSize;
    ctxParams.n_batch = request.batchSize;
    if (request.threads != null) {
      ctxParams.n_threads = request.threads!;
      ctxParams.n_threads_batch = request.threads!;
    }

    final ctx = bindings.llama_new_context_with_model(model, ctxParams);
    if (ctx.address == 0) {
      if (loraAdapter != null) {
        bindings.llama_adapter_lora_free(loraAdapter);
      }
      bindings.llama_free_model(model);
      mainSendPort.send(
        _IsolateResponse(
          requestId: request.requestId,
          payload: InferenceError('Failed to create context'),
          isComplete: true,
        ),
      );
      return;
    }

    if (loraAdapter != null) {
      final result = bindings.llama_set_adapter_lora(
        ctx,
        loraAdapter,
        request.loraScale,
      );
      if (result != 0) {
        bindings.llama_free(ctx);
        bindings.llama_adapter_lora_free(loraAdapter);
        bindings.llama_free_model(model);
        mainSendPort.send(
          _IsolateResponse(
            requestId: request.requestId,
            payload: InferenceError('Failed to apply LoRA adapter'),
            isComplete: true,
          ),
        );
        return;
      }
    }

    try {
      String prompt;
      // SWAYCO PATCH: a chat template emits the model's BOS itself, so the
      // tokenizer must not add a second one. Remember which path built the
      // prompt and pass that as add_special below.
      var templated = false;
      if (request.messages != null && request.messages!.isNotEmpty) {
        prompt = _applyNativeChatTemplate(bindings, model, request.messages!);
        templated = true;
      } else {
        prompt = request.prompt;
      }

      final promptPtr = prompt.toNativeUtf8();
      final maxTokens = prompt.length + 256;
      final tokensPtr = calloc<ffi.Int32>(maxTokens);

      final nTokens = bindings.llama_tokenize(
        vocab,
        promptPtr.cast(),
        prompt.length,
        tokensPtr,
        maxTokens,
        // add_special: off once templated. Hy-MT2's template opens with
        // <｜hy_begin▁of▁sentence｜>, which IS its BOS, so leaving this true fed
        // the model two BOS in a row and it replied with an endless run of that
        // very token instead of a translation. llama.cpp's own tools tokenize
        // template output with add_special off for exactly this reason.
        !templated,
        true, // parse_special: the template's markers must become token IDs
      );
      calloc.free(promptPtr);

      if (nTokens < 0) {
        calloc.free(tokensPtr);
        mainSendPort.send(
          _IsolateResponse(
            requestId: request.requestId,
            payload: InferenceError('Failed to tokenize prompt'),
            isComplete: true,
          ),
        );
        return;
      }

      final batch = bindings.llama_batch_get_one(tokensPtr, nTokens);
      if (bindings.llama_decode(ctx, batch) != 0) {
        calloc.free(tokensPtr);
        mainSendPort.send(
          _IsolateResponse(
            requestId: request.requestId,
            payload: InferenceError('Failed to evaluate prompt'),
            isComplete: true,
          ),
        );
        return;
      }

      final sampler = _configureSampler(bindings, request.options);
      final generatedTokens = _generateTokens(
        bindings,
        model,
        ctx,
        sampler,
        vocab,
        request.options,
        request.stopTokens,
        request.requestId,
        mainSendPort,
      );

      bindings.llama_sampler_free(sampler);
      calloc.free(tokensPtr);

      mainSendPort.send(
        _IsolateResponse(
          requestId: request.requestId,
          payload: InferenceComplete(
            promptTokens: nTokens,
            generatedTokens: generatedTokens,
          ),
          isComplete: true,
        ),
      );
    } finally {
      if (loraAdapter != null) {
        bindings.llama_clear_adapter_lora(ctx);
        bindings.llama_adapter_lora_free(loraAdapter);
      }
      bindings.llama_free(ctx);
      bindings.llama_free_model(model);
    }
  } catch (e) {
    mainSendPort.send(
      _IsolateResponse(
        requestId: request.requestId,
        payload: InferenceError(e.toString()),
        isComplete: true,
      ),
    );
  }
}
