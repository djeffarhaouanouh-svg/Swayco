/* Prove the patched sherpa GenerateFromTokens: load the ja fp16 model, feed the
 * Dart-phonemizer tokens, synthesise, write a WAV. Runs on sherpa's single ORT. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "c-api.h"

static int read_ints(const char *path, int64_t **tok, int32_t *ntok,
                     int64_t **tone, int32_t *ntone) {
  FILE *f = fopen(path, "r");
  if (!f) return 0;
  char line[65536];
  int64_t *arr[2] = {NULL, NULL};
  int32_t n[2] = {0, 0};
  for (int r = 0; r < 2 && fgets(line, sizeof(line), f); r++) {
    int cap = 16, c = 0;
    int64_t *a = malloc(cap * sizeof(int64_t));
    char *p = strtok(line, " \n");
    while (p) {
      if (c == cap) { cap *= 2; a = realloc(a, cap * sizeof(int64_t)); }
      a[c++] = atoll(p);
      p = strtok(NULL, " \n");
    }
    arr[r] = a; n[r] = c;
  }
  fclose(f);
  *tok = arr[0]; *ntok = n[0]; *tone = arr[1]; *ntone = n[1];
  return 1;
}

int main(int argc, char **argv) {
  const char *model = argv[1], *tokens = argv[2], *lexicon = argv[3];
  const char *tokfile = argv[4], *outwav = argv[5];

  SherpaOnnxOfflineTtsConfig config;
  memset(&config, 0, sizeof(config));
  config.model.vits.model = model;
  config.model.vits.tokens = tokens;
  config.model.vits.lexicon = lexicon;
  config.model.vits.noise_scale = 0.6f;
  config.model.vits.noise_scale_w = 0.8f;
  config.model.vits.length_scale = 1.0f;
  config.model.num_threads = 2;
  config.model.provider = "cpu";
  config.max_num_sentences = 1;

  const SherpaOnnxOfflineTts *tts = SherpaOnnxCreateOfflineTts(&config);
  if (!tts) { fprintf(stderr, "create failed\n"); return 1; }

  int64_t *tok, *tone; int32_t ntok, ntone;
  if (!read_ints(tokfile, &tok, &ntok, &tone, &ntone)) { fprintf(stderr, "read fail\n"); return 1; }
  fprintf(stderr, "tokens=%d tones=%d\n", ntok, ntone);

  const SherpaOnnxGeneratedAudio *audio =
      SherpaOnnxOfflineTtsGenerateFromTokens(tts, tok, ntok, tone, ntone, 0, 1.0f);
  if (!audio) { fprintf(stderr, "generate returned null\n"); return 1; }
  fprintf(stderr, "samples=%d sample_rate=%d\n", audio->n, audio->sample_rate);
  SherpaOnnxWriteWave(audio->samples, audio->n, audio->sample_rate, outwav);
  SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
  SherpaOnnxDestroyOfflineTts(tts);
  fprintf(stderr, "wrote %s\n", outwav);
  return 0;
}
