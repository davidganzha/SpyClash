# SpyClash 1.0.4 (238): App Store metadata draft

Prepared 13 November 2026. These are proposed changes, not saved App Store
Connect values. App: `6793534085`, bundle: `com.spyclash.ios`.

## Version and product

- Create iOS version **1.0.4** with **manual release** after approval.
- Attach the validated build **238** only after its upload and processing.
- New checkout product: `com.spyclash.ios.limitless.monthly` (`6825982027`),
  **ONE_MONTH**, configured United States price **USD 2.99**. Prices in other
  storefronts remain Apple's configured localized prices.
- Preserve the approved weekly product and existing subscriptions. The new
  client restores both products; this preparation does not cancel, transfer,
  reprice or migrate any existing subscription.
- The monthly product currently has `MISSING_METADATA`. Its version
  `ad15b177-6482-4129-9c47-3ebfafb0a633` is `PREPARE_FOR_SUBMISSION`.
  Review image and review note are missing. English, Russian and Spanish
  localizations exist; add the Ukrainian localization below.
- Use the current versioned subscription workflow for review metadata. Verify
  the readback before adding the product to the app-version review submission.

## English App Store description replacement

Retain the current description, keywords, support and marketing URLs, replacing
only the `FREE TO PLAY, OPTIONAL LIMITLESS` paragraph with:

The base game is free. LIMITLESS is an optional monthly auto-renewable
subscription that unlocks unlimited daily AI word generation, additional avatar
and Spycard customization, full match history, and advanced statistics. Existing
weekly subscriptions remain supported. Free accounts receive three AI word-pack
generations each day and can choose to watch a rewarded ad for one additional
generation. Active LIMITLESS members can generate without these ads.

Retain the existing Apple renewal/cancellation terms, account-deletion note,
privacy URL and Apple Standard EULA URL. The three-generation paragraph is
conditional on successful activation and acceptance of the reviewed reward
backend; do not publish it while the live service still uses the legacy quota.

## What's new

**en-US**

New ways to mix up your next match, a clearer game introduction, and compact
in-game controls. Explore 50 searchable theme ideas for your word packs.
LIMITLESS now offers a monthly subscription, with improved purchase and restore
handling. Free players can earn extra AI generations through optional ads.
Includes improvements to invitations, room synchronization and game stability.

**ru**

Новые варианты партий, обновлённое начало матча и компактные игровые кнопки.
Выбирайте из 50 тем для наборов слов с удобным поиском. LIMITLESS теперь можно
оформить на месяц; улучшены покупка и восстановление подписки. Дополнительные
AI-генерации доступны за добровольный просмотр рекламы. Улучшены приглашения,
синхронизация комнат и стабильность игры.

**uk**

Нові варіанти партій, оновлений початок матчу та компактні ігрові кнопки.
Обирайте серед 50 тем для наборів слів зі зручним пошуком. LIMITLESS тепер можна
оформити на місяць; поліпшено купівлю й відновлення підписки. Додаткові
AI-генерації доступні за добровільний перегляд реклами. Поліпшено запрошення,
синхронізацію кімнат і стабільність гри.

**es-ES**

Nuevas variantes de partida, una introducción más clara y controles compactos.
Explora 50 ideas de temas con búsqueda para tus paquetes de palabras.
LIMITLESS ahora ofrece una suscripción mensual y mejoras en compras y
restauración. Los jugadores gratuitos pueden obtener generaciones de IA
adicionales viendo anuncios opcionales. Mejoras en invitaciones, sincronización
de salas y estabilidad.

Only English is currently an app-version localization. Keep the other language
drafts for an explicitly approved localization addition; the app already
supports all four languages.

## Ukrainian monthly subscription localization

- Locale: `uk`
- Name: `SpyClash LIMITLESS на місяць`
- Description: `Безлімітні AI-слова та преміальні теми SpyClash.`

## Subscription review note

LIMITLESS Monthly is an auto-renewable subscription for one month. In the app,
sign in, open the LIMITLESS subscription screen from the profile, and tap
Subscribe. The app displays StoreKit's localized price and monthly period.
Use Restore Purchases on the same screen to restore an existing entitlement.
Existing weekly subscriptions are still recognized and are not converted by
this update. Paid access is granted only after server verification. The
subscription provides unlimited AI word-pack generation, avatar and Spycard
customization, full match history and advanced statistics. The base party game
remains available without subscribing. Optional rewarded ads are for extra
free-account generations; LIMITLESS does not require them.

Attach a current, unaltered in-app monthly paywall screenshot. Record whether
the capture used local StoreKit testing; a local screenshot is not proof of a
successful Apple sandbox purchase. Monthly purchase and restoration on the
distribution candidate remain acceptance gates before submission.

## Privacy and existing listing

The website privacy candidate is commit `36f61fbc` on
`davidganzha/app-store-privacy-238`. All 147 website tests and its production build
passed. It has not been published. Apply the reviewed App Store privacy changes
in `QA/app-store-candidate-20261111/privacy-readiness.md` after reconciling them
with the final SDK privacy report. The existing English listing has five
accepted 1320x2868 screenshots; preserve their records unless a reviewed
replacement is explicitly selected.

No upload, App Store metadata change, submission, product activation or public
release is authorized by this document.
