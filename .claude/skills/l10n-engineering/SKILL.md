---
name: l10n-engineering
description: Keep i18n/l10n/m17n robust — untranslated strings, raw identifiers, gettext extraction and hand review, terminology, locale and time-zone handling, and the gates. Run after any change to user-visible text, and before a release.
---

Locales: `en` (the source text), `zh_TW`, `ja_JP`. Domains: `default` (extracted) and
`errors` (**hand-maintained** `errors.pot`: changeset `message:` options and `add_error/3`
strings are invisible to extraction, so add their msgids by hand, then merge).

1. **Find untranslated text** in `lib/goodmao2_web` and any context text a person reads:
   bare English in templates, flashes, `aria-label`/`title`/`placeholder`/`alt`/
   `data-confirm`, `page_title`, notification, push and e-mail text, report PDFs/summaries.
   Wrap in `gettext()` (`ngettext()` when counted), with `%{var}`, never `"#{…}"` or
   concatenation.
   - **Raw identifiers** (`{x.status}`, `{x.type}`, a role, a species, a unit, a reason
     code) go through a translating helper (`translate_species/1`, `translate_role/1`,
     `translate_sex/1`, the log summary helpers). A helper covers every value of its
     source of truth; add a coverage test where none exists.
   - Error atoms reaching a flash go through a dedicated helper, never `inspect/1`.
2. **Extract:** `mix gettext.extract && mix gettext.merge priv/gettext`; read the new /
   fuzzy / removed counts. `errors.pot` msgids are added by hand before the merge.
3. **Zero fuzzy, in every locale and domain** (Gettext serves fuzzy guesses). Find them
   with `grep -n -A3 '^#,.*fuzzy' priv/gettext/*/LC_MESSAGES/*.po` and review every new
   msgid (`git diff priv/gettext/default.pot | grep '^+msgid'`) even if unflagged.
   - zh_TW / ja_JP: translate by hand against the msgid, drop `fuzzy` and `#|` lines.
   - en: blank the msgstr and drop the flag; never retype the English.
   - Plurals: zh_TW and ja_JP have `nplurals=1` (`msgstr[0]` only); en has two.
   - A reused msgid reuses its meaning; use a new msgid rather than a translation wrong in
     one place.
   - A translation that really is the English is written out with a translator comment.
   - Re-running the extract reports nothing new, reworded or removed.
3a. **Fix wrong translations that are not flagged**, in the same run: `grep -nE
   '用戶|繁體中文|正體中文'` (zh_TW); check msgids containing each table term use the
   settled translation; read short generic msgids near the change; check `%{…}` bindings
   match; blank any non-blank en msgstr. List the fixes (msgid, old, new) in the commit
   message.
4. **Terminology** (grep the `.po` files for the existing term first):

   | Concept | zh_TW | ja_JP |
   |---|---|---|
   | Pet | 寵物 | ペット |
   | Owner | 飼主 | 飼い主 |
   | Co-caretaker | 共同照護者 | 共同ケアラー |
   | Medication | 用藥 | 投薬 |
   | Weight | 體重 | 体重 |
   | Timeline | 時間軸 | タイムライン |
   | Notifications | 通知 | 通知 |
   | Messages | 訊息 | メッセージ |
   | Share | 分享 | 共有 |
   | User | 使用者 (never 用戶) | ユーザー |

   Extend the table when a recurring term is settled.
5. **Locale names are autonyms; `zh_TW` is 台灣漢語**, never 繁體中文 / 正體中文 (those
   name a script). The switcher and every policy page agree. The code stays `zh_TW`.
   Brand and tagline follow [ADR-0002](../../../doc/adr/0002-culture-first-localization.md).
6. **Runtime behaviour** near a change: locale resolution (`Plugs.Locale`, the `on_mount`),
   times through the time-zone policy (ADR-0018: `Plugs.Timezone`, `UserTimezone`,
   `TimezoneDetect`), nothing translated is frozen into a stored row (store data, translate
   at render), CJK and long tokens do not break layout (`features/layout_test.exs`), no
   content-blocker words in control names.
7. **Gates:** `test/goodmao2/locale_parity_test.exs` (domain parity, exact `.pot` match,
   no fuzzy, non-empty zh_TW/ja_JP, blank or identical en, matching bindings),
   `mix gettext.extract --check-up-to-date` (in `precommit`), any label-coverage tests
   touched, `mix precommit`, and after template/CSS changes `mix test.feature`
   (`js_errors_test.exs`, `layout_test.exs`).
8. **Document** a newly settled rule here or in `CLAUDE.md`.
9. **Commit** `.pot`/`.po` changes with their feature; a standalone fix is `fix(i18n): …`.
