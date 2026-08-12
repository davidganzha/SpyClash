import { motion } from "framer-motion";
import { useNavigate } from "react-router-dom";
import { createPageUrl } from "@/utils";
import Reveal from "@/components/Reveal";
import LanguageSwitcher from "@/components/LanguageSwitcher";
import { useLanguage } from "@/components/LanguageContext";
import { localize } from "@/components/i18n";

const UK_PRIVACY_SECTIONS = [
  {
    title: "1. ІНФОРМАЦІЯ, ЯКУ МИ ЗБИРАЄМО",
    text: "Оператором SpyClash і контролером даних цього сервісу є індивідуальний розробник David Ganzha. Ми збираємо інформацію, яку ви надаєте безпосередньо, зокрема адресу електронної пошти, відображуване ім'я, аватар, коментарі профілю та власні набори слів. Ми зберігаємо запити на дружбу, підтверджені дружні зв'язки та зв'язки із заблокованими гравцями, які утворюють ваш соціальний граф у сервісі. Підтверджених друзів може бути видно в профілях гравців. SpyClash не отримує доступу до адресної книги вашого пристрою й не завантажує її. Коли ви надсилаєте скаргу в Спільноті, ми зберігаємо вибрану причину, ідентифікатори облікових записів заявника та особи, на яку подано скаргу, а також приватний знімок відповідного коментаря, якщо це застосовно. Ми зберігаємо ідентифікатори облікових записів, приватний стан кімнат та ігор, історію матчів, рахунки й статистику гри. Ми обробляємо запити на генерацію за допомогою ШІ та зберігаємо згенеровані результати й обмежені метадані, пов'язані з обліковим записом. Наш власний кеш не зберігає необроблену тему або слова-виключення; у ньому зберігаються ідентифікатори запиту чи повтору, односторонні ключі теми та виключень, ключі мови, запитані й повернуті кількості, результати роботи кешу та спроб провайдерів. Деякі з цих полів, пов'язаних з обліковим записом, використовуються для оцінювання надійності генератора. Вони не використовуються для реклами чи відстеження між компаніями. Для доставлення сповіщень і Live Activities ми збираємо випадково згенерований ідентифікатор інсталяції, push-токени APNs та ActivityKit, стан дозволу й налаштування сповіщень, версію застосунку та вибрану мову або локаль. Ми також зберігаємо стани доставлення, кількість спроб і коди помилок, необхідні для повторного доставлення, відкликання недійсних токенів і діагностики збоїв сповіщень. Серверна частина Base44 зберігає односторонні хеші інсталяцій і токенів та шифрує необроблені push-токени. Ці реєстрації пов'язуються з вашим авторизованим обліковим записом лише для доставлення запитаних оновлень про гру, друзів, кімнати й матчі та не використовуються для реклами чи відстеження. Якщо у вашому обліковому записі є транзакція з припиненої платіжної програми, ми можемо зберігати обмежені ідентифікатори транзакцій провайдера, стан і дати для підтримки, вирішення спорів, бухгалтерського обліку, запобігання шахрайству та дотримання законодавства; ми не отримуємо повних даних вашої платіжної картки. Кадри QR-камери та дані ARKit Camera Assistance, що використовуються для стабілізації локального визначення відстані Nearby Interaction/Radar, обробляються на пристрої, не завантажуються й не зберігаються."
  },
  {
    title: "2. ЯК МИ ВИКОРИСТОВУЄМО ВАШУ ІНФОРМАЦІЮ",
    text: "Ми використовуємо зібрану інформацію для роботи й удосконалення гри, оцінювання надійності наявних функцій, розміщення та модерації користувацького вмісту, розслідування скарг у Спільноті, забезпечення дотримання Стандартів спільноти, надання підтримки, надсилання пов'язаних із грою сповіщень, а також відображення таблиць лідерів і статистики гравців."
  },
  {
    title: "3. ПЕРЕДАВАННЯ ДАНИХ",
    text: "Ми не продаємо вашу особисту інформацію. Base44 забезпечує автентифікацію, хостинг застосунку, зберігання бази даних, серверні функції та операційну інфраструктуру. Коли ви запитуєте набір слів, створений ШІ, тема, потрібна кількість, слова-виключення та мова надсилаються до налаштованої прямої кінцевої точки ШІ, якою за замовчуванням є OpenAI Responses API. У разі визначених операційних помилок або помилок конфігурації ті самі вхідні дані можуть додатково оброблятися через Base44 InvokeLLM; Base44 може обробляти цей резервний запит через налаштованого ним провайдера моделі ШІ. Обробка й зберігання на боці провайдера регулюються відповідними умовами та конфігурацією провайдера. Apple обробляє дані для функцій «Увійти з Apple», підтримки транзакцій App Store, доставлення сповіщень APNs та Live Activities ActivityKit. Для доставлення сповіщення або Live Activity серверна частина надсилає Apple токен і відповідне сповіщення або загальнодоступний набір даних про стан матчу. Ці дані можуть містити відображувані імена, символи аватарів, стан учасників, раунд, загальнодоступну категорію, таймер та ідентифікатори навігації, але не адресу електронної пошти, код входу до кімнати, роль або секретне слово. Google використовується лише тоді, коли ви обираєте вхід через Google. Stripe використовується лише за потреби для пошуку записів або вирішення спорів, пов'язаних із припиненою програмою вебплатежів. Ми обмежуємо розкриття даних описаними тут функціями сервісу та налаштовуємо й контролюємо наших постачальників послуг, щоб вони захищали персональні дані відповідно до цієї політики та чинного законодавства. Ваше відображуване ім'я, аватар, підтверджені друзі, коментарі профілю, змагальна статистика та вміст, яким ви вирішили поділитися, можуть бути видимими іншим гравцям SpyClash. Власний набір слів може бути показаний учасникам, коли ви виберете його для гри. Скарги в Спільноті та їхні знімки не є публічними й доступні лише вповноваженим адміністраторам і необхідним постачальникам послуг."
  },
  {
    title: "4. ЗБЕРІГАННЯ ДАНИХ",
    text: "Дані облікового запису зберігаються, доки він активний, або протягом описаних тут операційних строків. Варіанти кешу ШІ стають недійсними через сім днів, а записи успішного повтору — через 24 години; прострочені рядки можуть залишатися до запуску очищення, але більше не використовуються. Ви можете видалити обліковий запис у застосунку для iOS у розділі «Профіль» > «Небезпечна зона». Під час видалення буде видалено дані профілю, власні набори слів, запити на дружбу, підтверджені дружні зв'язки, блокування, коментарі профілю, запрошення до кімнат, посилання на активні кімнати, записи історії матчів, пов'язані з обліковим записом дані використання ШІ, кеш і записи повторів, реєстрації push-пристроїв та Live Activities. Ми намагаємося відкликати збережені облікові дані оновлення «Увійти з Apple» і очищаємо збережену нами копію. Якщо відкликання в Apple неможливо підтвердити, застосунок повідомить, що може знадобитися відкликання вручну. Для скарги в Спільноті, що стосується видаленого облікового запису, необроблені ідентифікатори замінюються стабільними маркерами видалення. Приватна скарга та знімок її вмісту можуть зберігатися лише стільки, скільки обґрунтовано потрібно для розслідування питань безпеки, застосування правил і ведення юридичних записів; доступ залишається обмеженим уповноваженими адміністраторами й необхідними постачальниками послуг. Обмежені записи про давні транзакції можуть зберігатися, якщо це потрібно для бухгалтерського обліку, запобігання шахрайству, вирішення спорів і виконання юридичних зобов'язань. Якщо у вас досі є давня платіжна угода, якою керує провайдер, видалення облікового запису не скасовує її; керуйте нею безпосередньо через цього провайдера."
  },
  {
    title: "5. ПРОДУКТОВІ МЕТРИКИ ТА СХОВИЩЕ ВЕБСАЙТУ",
    text: "SpyClash зберігає описані вище обмежені записи про взаємодію з продуктом, пов'язані з обліковим записом, для роботи застосунку й аналітики надійності функцій. Вебсайт використовує локальне сховище для мови та стану сеансу автентифікації. У релізній версії вебсайту вимкнено автоматичну сторонню й платформну аналітику використання сайту; нативний застосунок для iOS не містить SDK для реклами або міжзастосункового відстеження."
  },
  {
    title: "6. КОНФІДЕНЦІЙНІСТЬ ДІТЕЙ",
    text: "Наш сервіс не призначений для дітей віком до 13 років. Якщо ми дізнаємося, що без належного дозволу зібрали особисту інформацію дитини віком до 13 років, ми вживемо обґрунтованих заходів для її видалення."
  },
  {
    title: "7. ЗМІНИ ДО ЦІЄЇ ПОЛІТИКИ",
    text: "Ми можемо час від часу оновлювати цю Політику конфіденційності. Про зміни ми повідомлятимемо, публікуючи нову політику на цій сторінці з оновленою датою."
  },
  {
    title: "8. ЗВ'ЯЗОК ІЗ НАМИ",
    text: "Оператором SpyClash є David Ganzha. Щоб поставити запитання про конфіденційність, подати запит на доступ чи видалення або отримати іншу допомогу щодо прав на дані, скористайтеся актуальним способом зв'язку, опублікованим на https://spyclash.com/support."
  }
];

export default function PrivacyPolicy() {
  const navigate = useNavigate();
  const { lang } = useLanguage();

  return (
    <div style={{ minHeight: "calc(100vh - 80px)", padding: "60px 20px" }}>
      <LanguageSwitcher style={{ position: "fixed", top: 18, right: 18, zIndex: 20 }} />
      <div style={{ maxWidth: 760, margin: "0 auto" }}>
        <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }}>
          <div style={{ fontSize: 10, letterSpacing: 4, color: "#555", marginBottom: 12, textTransform: "uppercase" }}>{localize(lang, "Legal", "Правовая информация", "Правова інформація")}</div>
          <h1 style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 36, letterSpacing: 3, marginBottom: 8, color: "#fff" }}>
            {localize(lang, "PRIVACY POLICY", "ПОЛИТИКА КОНФИДЕНЦИАЛЬНОСТИ", "ПОЛІТИКА КОНФІДЕНЦІЙНОСТІ")}
          </h1>
          <div style={{ color: "#444", fontSize: 11, letterSpacing: 2, marginBottom: 48 }}>{localize(lang, "Last updated: July 2026", "Последнее обновление: июль 2026 г.", "Останнє оновлення: липень 2026 р.")}</div>

          <div style={{ display: "flex", flexDirection: "column", gap: 36 }}>
            {(lang === "uk" ? UK_PRIVACY_SECTIONS : [
              {
                title: "1. INFORMATION WE COLLECT",
                text: "SpyClash is operated by David Ganzha, an individual developer and the data controller for this service. We collect information you provide directly, including your email address, display name, avatar, profile comments, and custom word packs. We store friend requests, accepted friendships, and blocked-player relationships that form your in-service social graph. Accepted friends may be visible on player profiles. SpyClash does not access or upload your device address book. When you submit a Community report, we store the selected reason, the reporter and reported account identifiers, and a private snapshot of the reported comment when applicable. We store account identifiers, private room and game state, match history, scores, and gameplay statistics. We process AI-generation requests and retain generated results and limited account-linked metadata. Our own cache does not retain the raw theme or exclusion words; it stores request or replay identifiers, one-way theme and exclusion keys, language keys, requested and returned counts, cache outcomes, and provider-attempt results. Some of these account-linked fields are used to evaluate generator reliability. They are not used for advertising or cross-company tracking. To deliver notifications and Live Activities, we collect a randomly generated installation identifier, APNs and ActivityKit push tokens, notification authorization status and preferences, app version, and selected language or locale. We also retain delivery states, attempt counts, and error codes needed to retry delivery, revoke invalid tokens, and diagnose notification failures. The Base44 backend stores one-way installation and token hashes and encrypts raw push tokens. These registrations are linked to your signed-in account only to deliver requested game, friend, room, and match updates and are not used for advertising or tracking. If your account has a transaction from a retired billing program, we may retain limited provider transaction identifiers, status, and dates for support, disputes, accounting, fraud prevention, and legal compliance; we do not receive your full payment-card details. QR camera frames and ARKit Camera Assistance data used to stabilize local Nearby Interaction/Radar ranging are processed on device and are not uploaded or retained."
              },
              {
                title: "2. HOW WE USE YOUR INFORMATION",
                text: "We use the information we collect to operate and improve the game, measure the reliability of existing features, host and moderate user content, investigate Community reports, enforce the Community Standards, provide customer support, send game-related notifications, and display leaderboards and player statistics."
              },
              {
                title: "3. DATA SHARING",
                text: "We do not sell your personal information. Base44 provides authentication, application hosting, database storage, server functions, and operational infrastructure. When you request an AI word pack, the theme, requested count, exclusion words, and language are sent to the configured direct AI endpoint, which defaults to OpenAI's Responses API. On specified operational or configuration failures, the same input may also be processed through Base44 InvokeLLM; Base44 may process that fallback through its configured AI model provider. Provider-side processing and retention are governed by the applicable provider terms and configuration. Apple processes data for Sign in with Apple, App Store transaction support, APNs notification delivery, and ActivityKit Live Activities. To deliver a notification or Live Activity, the backend sends Apple the token and the corresponding alert or public match-state payload. These payloads may include display names, avatar symbols, participant status, round, public category, timer, and navigation identifiers, but not email, room join code, role, or secret word. Google is used only when you choose Google sign-in. Stripe is used only where needed to resolve records or disputes from a retired web-billing program. We limit disclosures to the service functions described here and configure and oversee our service providers to protect personal data consistently with this policy and applicable law. Your display name, avatar, accepted friends, profile comments, competitive statistics, and content you choose to share may be visible to other SpyClash players. A custom word pack may be shown to participants when you select it for a game. Community reports and their snapshots are not public and are available only to authorized administrators and necessary service providers."
              },
              {
                title: "4. DATA STORAGE",
                text: "Account data is retained while your account is active or for the operational periods described here. AI cache variants expire after seven days, and successful replay records expire after 24 hours; expired rows may remain until cleanup runs but are no longer used. You can delete the account in the iOS app under Profile > Danger Zone. Deletion removes profile data, custom word packs, friend requests, accepted friendships, blocks, profile comments, room invitations, active room references, match-history records, account-scoped AI usage, cache and replay records, push-device registrations, and Live Activity registrations. We attempt to revoke the stored Sign in with Apple refresh credential and scrub our stored copy. If Apple revocation cannot be confirmed, the app informs you that manual revocation may be required. For a Community report involving the deleted account, raw account identifiers are replaced with stable deletion tombstones. The private report and its content snapshot may be retained only as reasonably necessary for safety investigation, enforcement, and legal records; access remains limited to authorized administrators and necessary service providers. Limited legacy transaction records may be retained where needed for accounting, fraud prevention, dispute handling, and legal obligations. If you still have a provider-managed legacy billing agreement, account deletion does not cancel it; manage it directly with that provider."
              },
              {
                title: "5. PRODUCT METRICS AND WEBSITE STORAGE",
                text: "SpyClash retains the limited account-linked product-interaction records described above for app functionality and feature-reliability analytics. The website uses local storage for language and authentication session state. Automatic third-party and platform website-usage analytics are disabled in the release website; the native iOS app does not include advertising or cross-app tracking SDKs."
              },
              {
                title: "6. CHILDREN'S PRIVACY",
                text: "Our service is not directed to children under the age of 13. If we learn that we collected personal information from a child under 13 without valid authorization, we will take reasonable steps to delete it."
              },
              {
                title: "7. CHANGES TO THIS POLICY",
                text: "We may update this Privacy Policy from time to time. We will notify you of any changes by posting the new policy on this page with an updated date."
              },
              {
                title: "8. CONTACT US",
                text: "SpyClash is operated by David Ganzha. For privacy questions, access or deletion requests, or other data-rights assistance, use the current contact method published at https://spyclash.com/support."
              }
            ]).map((section, i) => (
              <Reveal key={i} delay={i * 30}>
                <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 14, letterSpacing: 3, color: "#e53535", marginBottom: 10 }}>
                  {section.title}
                </div>
                <div style={{ color: "#888", fontSize: 13, lineHeight: 1.9, letterSpacing: 0.5 }}>{section.text}</div>
              </Reveal>
            ))}
          </div>

          <div style={{ marginTop: 60, paddingTop: 24, borderTop: "1px solid #1a1a1a" }}>
            <button className="btn-ghost" style={{ fontSize: 11 }} onClick={() => navigate(createPageUrl("Home"))}>
              {localize(lang, "← BACK TO HOME", "← НА ГЛАВНУЮ", "← НА ГОЛОВНУ")}
            </button>
          </div>
        </motion.div>
      </div>
    </div>
  );
}
