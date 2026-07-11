/* OpenJTalk reading frontend for the on-device Japanese voice.
 * UTF-8 Japanese text -> katakana reading (== pyopenjtalk.g2p(text, kana=True)).
 * See native/ja_openjtalk/README.md and docs/ja_tts_engine_plan.md. */
#ifndef JA_FRONTEND_H
#define JA_FRONTEND_H

#ifdef __cplusplus
extern "C" {
#endif

/* Create a frontend from an open_jtalk UTF-8 dictionary directory.
 * Returns an opaque handle, or NULL on failure. */
void *ja_frontend_create(const char *dict_dir);

/* Destroy a handle from ja_frontend_create. */
void ja_frontend_destroy(void *handle);

/* Katakana reading of `text` as a malloc'd UTF-8 string (NULL on failure).
 * Free it with ja_frontend_free. Thread-compat: one handle is single-threaded;
 * use one handle per isolate/thread. */
char *ja_frontend_kana(void *handle, const char *text);

/* Free a string returned by ja_frontend_kana. */
void ja_frontend_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* JA_FRONTEND_H */
