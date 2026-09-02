# Lobby mode realtime pilot

Этот контур изолирует один эксперимент: переключение режима лобби
`Вопросы ↔ Ассоциации`. Он не меняет kick, close, голосования или остальные
realtime-события.

Целевой production app: `69a0e57fa939f578082f8091`.

Пакет намеренно не содержит `base44/.app.jsonc`, поэтому обычная команда из
его каталога не связана ни с одним Base44 app. Подготовка делает только
read-only снимки production и локальные файлы. Deploy в скрипте подготовки
отсутствует.

## Что входит в подготовленный stage

- `candidate`: свежие 24 production entity-схемы, где только
  `GameRoomSignal` дополнен пятью необязательными projection-полями, и только
  функция `gameRoomAction`. Функция упакована в непосредственно deployable
  flat-layout: `function.jsonc` и 43 соседних `.ts`-файла, без подкаталогов;
  `entry` равен `entry.ts`.
- `rollback`: только `gameRoomAction` в compatibility-off режиме. Новые поля
  остаются в schema, но generic-сигналы записывают `projection_kind: none`,
  поэтому сохранённая projection становится неактивной. Rollback строится
  только из запечатанного pre-cutover baseline, а не из уже работающего
  candidate, и имеет такой же flat-layout.
- `snapshots`: свежий read-only baseline всех entity и полные деревья всех 17
  production-функций, включая точную исходную версию `gameRoomAction`.
  Base44 CLI `functions pull` возвращает её в своём неизменённом nested-layout;
  snapshot никогда не нормализуется и не используется напрямую для deploy.
- `manifest.json`: app id, operator, Git commit, CLI version, inventories,
  hashes и строгий allowlist будущих production-команд. Manifest v2 раздельно
  запечатывает hash nested snapshot, hashes flat candidate/rollback и hashes
  ожидаемого nested pull-back после каждого deploy.

## Подготовка

Рабочее дерево должно быть чистым и находиться на проверенном commit:

```sh
./scripts/prepare-base44-lobby-mode-pilot.sh
```

Скрипт:

1. Проверяет canonical app, operator и `base44@0.0.56`.
2. Получает свежие schema и functions только на чтение.
3. Останавливается, если remote inventory или baseline `gameRoomAction`
   изменились.
4. Создаёт приватный stage в
   `.base44-cutover/lobby-mode-realtime-pilot/<run-id>`.
5. Запускает fail-closed verifier.

Preflight-разрешение stage действительно 2 минуты. После этого режим
`preflight` возвращает `BLOCKED_STALE_CUTOVER_PACKAGE`. Сам запечатанный пакет
остаётся пригодным для read-only postflight-аудита и подготовленного rollback;
нельзя пересобирать rollback из уже работающего production candidate.

Повторная локальная проверка:

```sh
./scripts/verify-base44-lobby-mode-pilot.sh \
  .base44-cutover/lobby-mode-realtime-pilot/<run-id> preflight
```

Каждый запуск verifier заново, только на чтение, получает все production-схемы
и все 17 функций. Во всех режимах он требует неизменности 16 non-target
функций. Неизвестный режим отклоняется fail-closed.

- `preflight` ожидает исходные function/schema и заканчивается
  `READY_FOR_APPROVAL`.
- `candidate-postflight` ожидает candidate function/schema и заканчивается
  `POSTFLIGHT_VERIFIED`.
- `rollback-preflight` подтверждает, что production ещё находится в candidate
  state, и заканчивается `READY_FOR_ROLLBACK_APPROVAL`; это не заменяет новое
  подтверждение пользователя.
- `rollback-postflight` ожидает compatibility-off функцию при сохранённой
  additive candidate schema и заканчивается `POSTFLIGHT_VERIFIED`.

Verifier сам не изменяет production и всегда выводит
`verification_mutated_production=false`.

## Production boundary

После `READY_FOR_APPROVAL` нужно остановиться. Никакая общая команда вроде
«продолжай» не разрешает production mutation. Непосредственно перед cutover
нужно назвать точный app id и две операции и получить новое однозначное
подтверждение пользователя.

После такого подтверждения порядок строго schema-first:

1. Ещё раз подготовить свежий stage и непосредственно перед schema push
   повторно запустить verifier; после `READY_FOR_APPROVAL` не ждать и не
   использовать stage старше двух минут.
2. Из `candidate` выполнить только argv из manifest для `entities push`.
3. Сразу подтвердить: entity count и names не изменились, `Created = 0`,
   `Deleted = 0`, изменён только `GameRoomSignal`.
4. Только после этого из `candidate` выполнить точный
   `functions deploy gameRoomAction` из manifest.
5. Повторно получить functions и доказать, что все 16 non-target functions
   сохранили hashes, запустив `candidate-postflight`.

Нельзя использовать `base44 deploy`, неназванный `functions deploy`,
`--force`, link/eject, site, auth, connector, secret или delete-команды.

## Двухустройственный latency test

Нужны два физических iPhone и два разных авторизованных аккаунта:

1. Создать новую waiting-комнату; устройство A — host, B — guest.
2. Снять оба экрана одной внешней камерой 120/240 fps.
3. Выполнить 30 последовательных переключений
   `Вопросы ↔ Ассоциации`, дожидаясь стабильного значения после каждого.
4. Для каждого переключения записать время от touch-down host до первого
   видимого изменения guest в `latency-results-template.csv`.
5. Сохранить guest-логи. Каждому переключению должна соответствовать строка
   `[LobbyModeRealtime] ... direct_apply=true`.

Критерии пилота:

- 30/30 правильных и стабильных переключений;
- 30/30 `direct_apply=true`, без fallback/reorder/revert;
- p50 не больше 250 ms;
- p95 не больше 500 ms;
- максимум меньше 1000 ms;
- ни в одном signal нет word, roles, word pool или player payload;
- нет новых 5xx, lease/deadline ошибок или зависшего состояния.

Deploy сам по себе не означает успех. Пилот принят только после этого
двухаккаунтного теста.

## Rollback

Rollback — отдельная production mutation и требует отдельного свежего
подтверждения. После подтверждения можно deploy только `gameRoomAction` из
каталога `rollback`, используя точный rollback argv из manifest.

Непосредственно перед запросом подтверждения нужно запустить
`rollback-preflight`; после deploy — `rollback-postflight`. Запрещено
пересобирать rollback из live candidate: это сохранило бы включённый fast path.

Старую entity schema автоматически возвращать нельзя: пять полей additive и
optional, а полный schema push имеет риск затронуть другие entities.
