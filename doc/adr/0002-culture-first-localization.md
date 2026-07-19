# 2. Culture-first localization: site name and tagline naming policy

- **Status:** Accepted
- **Date:** 2026-07-09
- **Deciders:** GoodMao maintainers

## Context

GoodMao ships in three locales — **en** (base), **zh-TW**, and **ja-JP** — and
its brand is deliberately warm: **顧毛** is a coined Han-character name meaning
**照顧毛小孩** ("care for your fluffy kids"), where 毛小孩 ("fluffy kids") is a
Taiwanese term of endearment for pets.

That branding does not survive a literal, word-for-word rendering into other
locales:

- **顧毛** is a coined compound; a Japanese reader recognises the individual
  kanji but cannot parse the intended brand meaning.
- **毛小孩 → "fluffy kids"** reads as an uncommon expression in English, and
  **毛小孩 → 毛の子** reads as unnatural in Japanese (it is a carried-over Chinese
  metaphor, not native Japanese).
- Even the language menu is culturally loaded: labelling zh-TW as "繁體中文"
  ("Traditional Chinese") is not how this project chooses to name it.

Transliterating the source strings would produce copy that is technically
translated but culturally wrong. We need a standing policy so every present and
future UI string is handled consistently.

## Decision

**We localize UI copy to its cultural context — translating meaning and intent
for the target audience — rather than transliterating the Chinese source name or
metaphor across locales.**

Applied to the site name and tagline (all driven by **Gettext** messages, kept in sync
across `priv/gettext/{en,zh_TW,ja_JP}/LC_MESSAGES/`):

| Concept | en | zh-TW | ja-JP |
| --- | --- | --- | --- |
| Brand / logo wordmark | **GoodMao** | 顧毛 | **グッドマオ** (katakana) |
| Pet endearment (tagline) | "Take care of your **pets**." | "照顧您的**毛小孩**。" | "大切な**ペット**を見守ろう。" |
| Home title | "GoodMao — Take care of your pets" | "顧毛 — 照顧您的毛小孩" | "グッドマオ — 大切なペットを見守ろう" |
| zh-TW locale label | 台灣漢語 | 台灣漢語 | 台灣漢語 |

Rules that follow from the policy:

- **Brand name:** zh-TW keeps the Han wordmark **顧毛**; English uses the Latin
  **GoodMao**; Japanese uses the katakana transliteration **グッドマオ** (the kanji
  coinage is not readable as a brand). Never hard-code the brand — render it through a
  Gettext-backed brand string (a `Goodmao2Web.Helpers` helper is the natural home), so
  the wordmark is data that varies per locale.
- **Pet term:** the 毛小孩 endearment is intentional **only in zh-TW**. Other
  locales use their own natural term — English **"pets"** (not "fluffy kids"),
  Japanese **ペット** (not 毛の子).
- **Locale names:** the zh-TW locale is always labelled **台灣漢語** (never
  "繁體中文"/"正體中文").
- The `en` catalog is the base/reference, but "base" means default, not
  "authoritative wording to be copied literally" into the others.

## Consequences

- Copy reads as native in each locale; the brand still feels warm without being
  mistranslated.
- Every user-facing string is a translation decision, not a transliteration —
  translators/contributors must consider the target culture, which is slightly
  more effort than string-for-string translation (intended).
- The brand name is data (a Gettext message), so new surfaces that show it stay
  consistent for free, and adding or adjusting a locale's form needs no code change.
- After adding or changing any `gettext()` string, run
  `mix gettext.extract && mix gettext.merge priv/gettext` and keep all three catalogs in
  sync (a locale-parity discipline; see [`../../CLAUDE.md`](../../CLAUDE.md)).
- Keep [`../glossary.md`](../glossary.md) and the message catalogs in sync with this
  policy.

## Alternatives considered

- **Literal translation of the source strings** — produces "fluffy kids" / 毛の子
  / 繁體中文, which are awkward or culturally off; rejected as the whole reason
  for this ADR.
- **One global brand spelling (always 顧毛, or always "GoodMao")** — ignores that
  the kanji coinage is unreadable to Japanese users and that Latin script suits
  the English surface; rejected in favour of a per-locale brand message.
