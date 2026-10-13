# Hybrid privacy wording — review draft

Prepared for the native Supabase candidate. This document is not published and does not change the public website policy. The original Base44 app keeps its existing in-app wording. The candidate's in-app privacy text uses the paragraphs below in its four supported languages and retains the existing weekly subscription and account-deletion notices.

Before publishing, confirm which billing and notification features are enabled in the approved build and deployed backend. Their adapters are currently prepared behind configuration gates; this text does not represent production activation or a new retention commitment.

## English

This version uses Supabase for app sessions, profiles, contact email, rooms and game state, word packs, social relationships, match history, and the private link between your existing Base44 account identifier and your Supabase account identifier. Base44 continues to handle the existing sign-in and account-email flows and AI word generation. Depending on the service configuration, AI generation can use OpenAI directly from the Base44 backend or Base44 InvokeLLM, including as a fallback. Where enabled, Base44 also verifies and synchronizes subscription payments and relays notifications to Apple; Supabase stores the corresponding access status, notification registrations and delivery records. Data transferred between these services is used for those functions.

When notifications are enabled for this version, Supabase links notification registrations to your account and stores installation identifiers, one-way token hashes, and encrypted push tokens. Base44 relays the token and permitted notification payload to Apple's delivery service.

## Español

Esta versión usa Supabase para las sesiones de la aplicación, los perfiles, el correo de contacto, las salas y el estado del juego, los paquetes de palabras, las relaciones sociales, el historial de partidas y el vínculo privado entre el identificador de tu cuenta existente de Base44 y el de Supabase. Base44 sigue gestionando los procesos existentes de inicio de sesión y correo de la cuenta y la generación de palabras con IA. Según la configuración del servicio, la generación con IA puede usar OpenAI directamente desde el backend de Base44 o Base44 InvokeLLM, también como alternativa de respaldo. Cuando están habilitados, Base44 también verifica y sincroniza los pagos de suscripciones y transmite las notificaciones a Apple; Supabase almacena el estado de acceso correspondiente, los registros de notificaciones y los de entrega. Los datos transferidos entre estos servicios se usan para esas funciones.

Cuando las notificaciones están habilitadas para esta versión, Supabase vincula sus registros con tu cuenta y almacena identificadores de instalación, hashes unidireccionales de los tokens y tokens push cifrados. Base44 transmite el token y el contenido permitido de la notificación al servicio de entrega de Apple.

## Русский

Эта версия использует Supabase для сессий приложения, профилей, контактного email, комнат и состояния игры, наборов слов, социальных связей, истории матчей и приватной связи между идентификаторами вашего существующего аккаунта Base44 и аккаунта Supabase. Base44 продолжает обслуживать существующие сценарии входа, письма аккаунта и AI-генерацию слов. В зависимости от конфигурации сервиса AI-генерация может использовать OpenAI напрямую из серверной части Base44 или Base44 InvokeLLM, в том числе как резервный вариант. Когда эти функции включены, Base44 также проверяет и синхронизирует оплату подписок и передаёт уведомления Apple; Supabase хранит соответствующий статус доступа, регистрации уведомлений и записи доставки. Данные между этими сервисами передаются для выполнения этих функций.

Когда уведомления включены для этой версии, Supabase связывает их регистрации с вашим аккаунтом и хранит идентификаторы установки, односторонние хэши токенов и зашифрованные push-токены. Base44 передаёт токен и разрешённое содержимое уведомления службе доставки Apple.

## Українська

Ця версія використовує Supabase для сесій застосунку, профілів, контактного email, кімнат і стану гри, наборів слів, соціальних зв’язків, історії матчів та приватного зв’язку між ідентифікаторами вашого наявного акаунта Base44 й акаунта Supabase. Base44 і надалі обслуговує наявні сценарії входу, листи акаунта та AI-генерацію слів. Залежно від конфігурації сервісу AI-генерація може використовувати OpenAI безпосередньо із серверної частини Base44 або Base44 InvokeLLM, зокрема як резервний варіант. Коли ці функції ввімкнені, Base44 також перевіряє й синхронізує оплату підписок та передає сповіщення Apple; Supabase зберігає відповідний статус доступу, реєстрації сповіщень і записи доставки. Дані між цими сервісами передаються для виконання цих функцій.

Коли сповіщення ввімкнені для цієї версії, Supabase пов’язує їхні реєстрації з вашим акаунтом і зберігає ідентифікатори встановлення, односторонні хеші токенів та зашифровані push-токени. Base44 передає токен і дозволений вміст сповіщення службі доставки Apple.
