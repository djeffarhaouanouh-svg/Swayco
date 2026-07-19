part of 'persistent_inference_isolate.dart';

/// Generates tokens and sends them via the send port.
///
/// Returns the number of generated tokens.
int _generateTokens(
  LlamaBindings bindings,
  ffi.Pointer<llama_model> model,
  ffi.Pointer<llama_context> ctx,
  ffi.Pointer<llama_sampler> sampler,
  ffi.Pointer<llama_vocab> vocab,
  GenerationOptions options,
  List<String> stopTokens,
  int requestId,
  SendPort mainSendPort,
) {
  const bufferSize = 256;
  var pieceBuffer = calloc<ffi.Char>(bufferSize);
  var generatedTokens = 0;
  final newTokenPtr = calloc<ffi.Int32>(1);

  /// Bytes emitted by the model that do not yet form whole UTF-8 characters.
  final pending = <int>[];

  while (generatedTokens < options.maxTokens) {
    final newToken = bindings.llama_sampler_sample(sampler, ctx, -1);

    if (bindings.llama_vocab_is_eog(vocab, newToken)) {
      break;
    }

    var pieceLen = bindings.llama_token_to_piece(
      vocab,
      newToken,
      pieceBuffer,
      bufferSize,
      0,
      true,
    );

    if (pieceLen < 0) {
      final requiredSize = -pieceLen;
      calloc.free(pieceBuffer);
      pieceBuffer = calloc<ffi.Char>(requiredSize);
      pieceLen = bindings.llama_token_to_piece(
        vocab,
        newToken,
        pieceBuffer,
        requiredSize,
        0,
        true,
      );
    }

    if (pieceLen > 0) {
      // SWAYCO PATCH: decode across token boundaries, not per token.
      //
      // A token's bytes are not necessarily a whole character: llama.cpp splits
      // multi-byte UTF-8 wherever the tokenizer happens to cut, so one piece can
      // carry the first 2 bytes of a 3-byte Japanese glyph and the next piece the
      // third. Decoding each piece on its own threw "FormatException: Unfinished
      // UTF-8 octet sequence" and killed the whole translation. Pure ASCII output
      // never hit it, which is why it only surfaced once the model finally
      // started answering in Japanese.
      //
      // Buffer the raw bytes and hand out only the complete characters, keeping
      // any dangling lead+continuation bytes for the next token.
      pending.addAll(pieceBuffer.cast<ffi.Uint8>().asTypedList(pieceLen));

      final hold = _incompleteUtf8Tail(pending);
      final ready = pending.length - hold;
      if (ready > 0) {
        final piece = utf8.decode(
          Uint8List.fromList(pending.sublist(0, ready)),
          allowMalformed: true,
        );
        pending.removeRange(0, ready);

        bool shouldStop = false;
        for (final stopToken in stopTokens) {
          if (piece.contains(stopToken)) {
            shouldStop = true;
            break;
          }
        }

        if (shouldStop) break;

        mainSendPort.send(
          _IsolateResponse(
            requestId: requestId,
            payload: InferenceToken(piece),
            isComplete: false,
          ),
        );
      }
    }

    newTokenPtr[0] = newToken;
    final batch = bindings.llama_batch_get_one(newTokenPtr, 1);
    if (bindings.llama_decode(ctx, batch) != 0) {
      break;
    }

    generatedTokens++;
  }

  // Anything still buffered is a truncated character (the model stopped
  // mid-glyph, or we hit maxTokens). Emit it as replacement chars rather than
  // silently dropping bytes.
  if (pending.isNotEmpty) {
    mainSendPort.send(
      _IsolateResponse(
        requestId: requestId,
        payload: InferenceToken(
          utf8.decode(Uint8List.fromList(pending), allowMalformed: true),
        ),
        isComplete: false,
      ),
    );
  }

  calloc.free(pieceBuffer);
  calloc.free(newTokenPtr);

  return generatedTokens;
}

/// How many bytes at the end of [b] belong to a UTF-8 character that is not
/// finished yet, and so must wait for the next token.
///
/// Returns 0 when the buffer ends on a character boundary. A lead byte encodes
/// its own length (110xxxxx = 2 bytes, 1110xxxx = 3, 11110xxx = 4), so we scan
/// back to the nearest lead byte and compare how many bytes actually followed.
int _incompleteUtf8Tail(List<int> b) {
  for (var back = 1; back <= 4 && back <= b.length; back++) {
    final c = b[b.length - back];
    if (c & 0x80 == 0) return 0; // ASCII: a boundary
    if (c & 0xC0 == 0x80) continue; // continuation byte: keep scanning back
    final need = c & 0xE0 == 0xC0
        ? 2
        : c & 0xF0 == 0xE0
            ? 3
            : c & 0xF8 == 0xF0
                ? 4
                : 0; // not a valid lead byte — let the decoder deal with it
    return need > back ? back : 0;
  }
  return 0;
}
