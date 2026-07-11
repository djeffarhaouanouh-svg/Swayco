/* Minimal OpenJTalk *reading* frontend: UTF-8 Japanese text -> katakana reading,
 * matching pyopenjtalk.g2p(text, kana=True). No HTS voice / synthesis: we only
 * run mecab + NJD and concatenate each node's `pron`, stripping the U+2019
 * accent mark (’) exactly as pyopenjtalk's kana path does.
 *
 * The katakana it returns is consumed by the Dart phonemizer
 * (expandChoonpu -> phonemizeKatakana) to drive the MeloTTS-ONNX ja model. */
#include <stdlib.h>
#include <string.h>

#include "ja_frontend.h"  /* extern "C" guard -> unmangled C symbols under clang++ */
#include "mecab.h"
#include "njd.h"
#include "text2mecab.h"
#include "mecab2njd.h"
#include "njd_set_pronunciation.h"
#include "njd_set_digit.h"
#include "njd_set_accent_phrase.h"
#include "njd_set_accent_type.h"
#include "njd_set_unvoiced_vowel.h"
#include "njd_set_long_vowel.h"

typedef struct {
  Mecab mecab;
  NJD njd;
} JaFrontend;

/* Create a frontend from an open_jtalk UTF-8 dictionary directory.
 * Returns NULL on failure. */
void *ja_frontend_create(const char *dict_dir) {
  JaFrontend *f = (JaFrontend *)calloc(1, sizeof(JaFrontend));
  if (!f) return NULL;
  Mecab_initialize(&f->mecab);
  NJD_initialize(&f->njd);
  if (Mecab_load(&f->mecab, dict_dir) != TRUE) {
    Mecab_clear(&f->mecab);
    NJD_clear(&f->njd);
    free(f);
    return NULL;
  }
  return f;
}

void ja_frontend_destroy(void *handle) {
  if (!handle) return;
  JaFrontend *f = (JaFrontend *)handle;
  Mecab_clear(&f->mecab);
  NJD_clear(&f->njd);
  free(f);
}

/* Free a string returned by ja_frontend_kana. */
void ja_frontend_free(char *s) { free(s); }

/* Return the katakana reading of `text` as a malloc'd UTF-8 string (caller frees
 * via ja_frontend_free). Returns NULL on failure. */
char *ja_frontend_kana(void *handle, const char *text) {
  if (!handle || !text) return NULL;
  JaFrontend *f = (JaFrontend *)handle;

  size_t in_len = strlen(text);
  /* text2mecab escapes; be generous. */
  size_t buf_len = in_len * 8 + 1024;
  char *buff = (char *)malloc(buf_len);
  if (!buff) return NULL;
  buff[0] = '\0';
  text2mecab(buff, text);

  Mecab_analysis(&f->mecab, buff);
  mecab2njd(&f->njd, Mecab_get_feature(&f->mecab), Mecab_get_size(&f->mecab));
  njd_set_pronunciation(&f->njd);
  njd_set_digit(&f->njd);
  njd_set_accent_phrase(&f->njd);
  njd_set_accent_type(&f->njd);
  njd_set_unvoiced_vowel(&f->njd);
  njd_set_long_vowel(&f->njd);

  /* Concatenate node prons. */
  size_t cap = 256, len = 0;
  char *out = (char *)malloc(cap);
  if (!out) { free(buff); NJD_refresh(&f->njd); Mecab_refresh(&f->mecab); return NULL; }
  for (NJDNode *node = f->njd.head; node != NULL; node = node->next) {
    const char *pron = NJDNode_get_pron(node);
    if (!pron) continue;
    size_t pl = strlen(pron);
    if (len + pl + 1 > cap) {
      while (len + pl + 1 > cap) cap *= 2;
      char *n = (char *)realloc(out, cap);
      if (!n) { free(out); out = NULL; break; }
      out = n;
    }
    memcpy(out + len, pron, pl);
    len += pl;
  }
  if (out) out[len] = '\0';

  NJD_refresh(&f->njd);
  Mecab_refresh(&f->mecab);
  free(buff);
  if (!out) return NULL;

  /* Strip the U+2019 accent mark (’ = 0xE2 0x80 0x99). */
  char *dst = out;
  for (const unsigned char *p = (unsigned char *)out; *p;) {
    if (p[0] == 0xE2 && p[1] == 0x80 && p[2] == 0x99) { p += 3; continue; }
    *dst++ = (char)*p++;
  }
  *dst = '\0';
  return out;
}
