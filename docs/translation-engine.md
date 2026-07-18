# Moteur de traduction — tests, hypothèses, modèles

Notes de la session d'exploration (juillet 2026) sur le choix du moteur de
traduction texte→texte de `/translation/text`. STT et TTS tournent déjà
on-device ; **la traduction est le seul coût cloud d'un appel**, donc le seul
poste qui grandit avec le succès.

⚠️ Chiffres : **MESURÉ** = relevé sur l'API réelle ce jour. **ESTIMÉ** = calcul
avec une hypothèse. L'hypothèse de débit (**6 traductions/min d'appel**) est
**inventée** — le vrai débit est dans les analytics (`text_translation` events),
à mesurer pour fiabiliser tous les montants. Tarifs relevés sur les pages
officielles (datées : gpt-4.1 est **legacy**, la gamme actuelle est gpt-5.x).

---

## État déployé (aujourd'hui)

- `/translation/text` : fournisseur **pilotable par variables d'env**, sans
  toucher au code (`backend/server.js`).
  - `TRANSLATE_BASE` / `TRANSLATE_MODEL` / `TRANSLATE_KEY` / `TRANSLATE_REASONING_EFFORT`
  - Défaut si rien n'est posé : **OpenAI + gpt-4.1** (prod intacte).
  - **La bascule s'arme quand `TRANSLATE_KEY` ET `TRANSLATE_MODEL` sont posés**
    ensemble → OVHcloud (Gravelines) + `low`. Une clé seule ne bascule pas
    (sinon 401 sur chaque phrase).
  - Le **modèle** n'est jamais nommé dans le code (vient de l'env) ; l'hôte OVH,
    lui, est visible (EU = argument, pas secret).
- **Cible du déploiement** : `gpt-oss-20b` + `reasoning_effort=low` sur OVH.
  → poser sur Railway : `TRANSLATE_KEY=<clé OVH>` + `TRANSLATE_MODEL=gpt-oss-20b`.
- **Prompt** : complet pour le chat, **allégé pour la voix** (`speech:true` →
  on retire emojis/@mentions/#/URL + ponctuation, inutiles à l'oral).
- **`resolveGenderHedges()`** (filet code) : résout « content(e) », « venu(e) »,
  « nouveau/nouvelle » de façon déterministe à partir des genres connus.
  **Masculin par défaut** si genre inconnu → couvre 100 % des cas. Testé **8/8**,
  laisse les URL intactes.

---

## Modèles testés

Coût = **ESTIMÉ** à 1000 appels d'1h/jour (6 trad/min), tokens de sortie
**facturés MESURÉS** (⚠️ les modèles de raisonnement facturent la « réflexion »
qu'on ne voit jamais).

| Modèle | Héberg. | Sortie facturée | $/mois (est.) | Répare charabia dur | Genre |
|---|---|---|---|---|---|
| **gpt-oss-20b + low** | OVH 🇫🇷 | ~51 tok | **~337-351** | ❌ | ✅ |
| gpt-oss-20b (base) | OVH 🇫🇷 | ~270 tok | ~733 | ❌ | ✅ |
| gpt-oss-120b + low | OVH 🇫🇷 | ~63 tok | ~816 | non testé | non testé |
| **DeepSeek V4 Flash** | 🇨🇳 | ~300 tok (reasoning) | **~1100** | ✅ | ⚠️ peer=f |
| gpt-4.1-mini | 🇺🇸 | ~15 tok | ~1188 | ❌ | ✅ |
| gpt-4.1 (défaut actuel) | 🇺🇸 | ~15 tok | **~4541-5945** | ✅ | ✅ |
| NLLB-200-distilled-600M | on-device | — | ~0 (device) | ❌❌ | ❌ (pas de prompt) |

Notes :
- **gpt-oss-20b + low** : MESURÉ bon sur ja/fr propres (20 phrases). Sur charabia
  rare (lituanien) : rate « les chats ont travaillé » (comme mini/nano). Le
  `low` divise la sortie facturée par ~5 sans perte sur ja (peu genré) ; sur fr
  ~2 accrocs/40 (accord masculin, tournure), **compréhensibles**.
- **DeepSeek Flash** : réflexion **non désactivable** (thinking/enable_thinking/
  /no_think tous ignorés ou 400). Cette réflexion est **ce qui lui permet de
  réparer** le charabia. Open-weight **MIT** mais **~570 Go** → auto-héberger =
  8×H100 (~26k$/mois), rentable seulement > ~71 000 appels d'1h/jour → **API
  uniquement**.
- **NLLB** : ~600 Mo int8, ~657 Mo RAM, **~490 ms/phrase** (CPU desktop, runtime
  CTranslate2 ; PyTorch fp32 donnait 1550 ms = mauvais benchmark). int8 est le
  **plancher** (formats plus légers = GPU only ; int4 casserait le CJK comme le
  STT). Multilingue (200 langues, un seul modèle).

---

## Hypothèses testées

- **H1 — « NLLB est bon sur les langues rares » → À MOITIÉ, puis REJETÉ pour la
  pipeline directe.** Excellent sur du texte **propre** (LT, JA), mais **la vraie
  entrée = charabia du STT**, et là il traduit le bruit **littéralement** :
  「Katų veikė」→ « les chats ont travaillé », 「buvolo baismagu」→ « mon père de
  poule ». 3/4 charabia = non-sens total. Un traducteur spécialisé n'a aucune
  connaissance du monde pour reconstruire.

- **H2 — « Réparer le charabia = plus de réflexion » → REJETÉ.** gpt-oss-20b en
  BASE (réflexion complète, 568-790 tok) ne fait **pas** mieux que `low` sur le
  cas dur — et hallucine même plus (« l'éléphant »). C'est de la **connaissance/
  taille**, pas de la réflexion.

- **H3 — « La réparation dépend de la TAILLE du modèle » → CONFIRMÉ.**
  Échelle mesurée sur charabia lituanien : `gpt-4.1 ≈ DeepSeek Flash` (réparent
  tout) `≫ gpt-oss-20b ≈ gpt-4.1-mini ≈ nano` (butent sur « les chats »)
  `> NLLB` (traduit le bruit). **gpt-4.1-mini n'est PAS un substitut moins cher**
  de gpt-4.1 : plus cher que gpt-oss ET échoue le repair dur.

- **H4 — Pipeline 3 étages : STT→DeepSeek(corrige la source)→NLLB(traduit) →
  MARCHE (mesuré).** DeepSeek corrige en langue source (「Katų veikė savait galį」
  → 「Ką tu veiki savaitgalį?」), NLLB traduit du propre → les 4 cassées
  réparées. **Restes** : NLLB dit encore « vous » (registre), et l'économie
  dépend du **gating** (voir mois 2).

- **H5 — Raccourcir le prompt DeepSeek (78 vs 461 tok) → MITIGÉ.** Meilleur sur
  le **genre** (formulation explicite « the addressee is a WOMAN » corrige les
  misses peer=f de DeepSeek), mais **régression** sur un repair dur, et pour
  DeepSeek l'économie est **faible** (coût dominé par la sortie/réflexion, pas
  l'entrée déjà cachée).

- **H6 — Où part la facture.** OVH/gpt-oss (pas de cache) : le **prompt système**
  répété = ~80 % de l'entrée → alléger le prompt aide. DeepSeek : la **sortie/
  réflexion** domine → alléger le prompt aide peu. gpt-oss + low : après repair
  du prompt, la sortie ne fait plus que ~5 % → c'est l'entrée (prompt) qui pèse.

- **Correctif au passage** : gpt-oss-20b **gère déjà** le genre du correspondant
  (peer=f → « gentille », « nouvelle »). Le problème peer=f était **DeepSeek**,
  pas gpt-oss. **Rien à corriger sur le déploiement actuel.**

---

## Architecture cible (mois 2+)

```
LANGUE EASY (STT propre : ja, fr, es, en…)   -> gpt-oss-20b + low   (cloud OVH, cheap)
LANGUE RARE (STT bruité : lt, lv, et…)       -> DeepSeek Flash : petit prompt
                                                 "corrige {langue parlée} + traduis {cible}
                                                  + registre tu + genre EXPLICITE"
NLLB on-device                               -> RÉSERVE (mois 3+), quand le volume
                                                 justifie 600 Mo sur le tel
```

- **Le vrai levier de coût = le gating** : n'appeler le cloud **que quand le STT
  est incertain** (score de confiance < seuil). Les phrases bien reconnues → pas
  d'appel cloud (ou NLLB gratuit si on-device). Diviserait la facture bien plus
  que le routage par langue seul.
- DeepSeek = 🇨🇳 : si RGPD bloque sur les rares, `gpt-4.1` à la place (même repair,
  4× plus cher, mais 🇺🇸 et faible volume). OVH n'héberge **pas** DeepSeek.

---

## Questions ouvertes (à vérifier avant de s'engager)

1. **Débit réel** (traductions/min d'appel) → analytics `text_translation`.
   Recale TOUS les montants de ce doc.
2. **NLLB : latence sur un VRAI téléphone** (pas desktop) → ~800-1500 ms probable.
   Décide si l'on-device est jouable.
3. **600 Mo sur le tel** acceptable pour l'adoption ? (frein à l'install).
4. **Signal de confiance STT** pour gater l'appel cloud — existe-t-il, exploitable ?
5. **Qualité par langue** : tester NLLB / gpt-oss / DeepSeek sur 20+ phrases par
   langue de marché avant de figer la table de routage.
6. **DeepSeek petit prompt** : la régression repair est-elle de la variance
   (réflexion 125-559 tok très variable) ou réelle ?
