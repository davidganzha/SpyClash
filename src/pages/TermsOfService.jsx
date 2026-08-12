import { motion } from "framer-motion";
import { useNavigate } from "react-router-dom";
import { createPageUrl } from "@/utils";
import Reveal from "@/components/Reveal";
import LanguageSwitcher from "@/components/LanguageSwitcher";
import { useLanguage } from "@/components/LanguageContext";
import { localize } from "@/components/i18n";

const UK_TERMS = [
  {
    title: "1. ПРИЙНЯТТЯ УМОВ",
    text: "Оператором SpyClash є David Ganzha. Отримуючи доступ до SpyClash або користуючись ним, ви погоджуєтеся дотримуватися цих Умов використання. Якщо ви не погоджуєтеся з ними, не користуйтеся нашим сервісом."
  },
  {
    title: "2. ВИКОРИСТАННЯ СЕРВІСУ",
    text: "SpyClash — це багатокористувацька гра на соціальну дедукцію, призначена для розваг. Щоб користуватися сервісом, вам має бути щонайменше 13 років. Ви погоджуєтеся використовувати сервіс лише в законних цілях і так, щоб не порушувати прав інших осіб."
  },
  {
    title: "3. ВІДПОВІДАЛЬНІСТЬ ЗА ОБЛІКОВИЙ ЗАПИС",
    text: "Ви відповідаєте за конфіденційність даних для входу та за всі дії, виконані з вашого облікового запису. Ви погоджуєтеся негайно повідомити нас про будь-яке несанкціоноване використання вашого облікового запису."
  },
  {
    title: "4. ЧЕСНА ГРА",
    text: "Ви погоджуєтеся грати чесно й не використовувати чити, уразливості, засоби автоматизації, ботів, злами або будь-яке несанкціоноване стороннє програмне забезпечення, що може впливати на ігровий процес. Порушення можуть призвести до призупинення або видалення облікового запису."
  },
  {
    title: "5. ВМІСТ",
    text: "Ви погоджуєтеся не використовувати гру для передавання незаконного, шкідливого, погрозливого, образливого, переслідувального, наклепницького або іншого неприйнятного вмісту. Ми залишаємо за собою право видаляти будь-який вміст, що порушує ці умови."
  },
  {
    title: "6. КОРИСТУВАЦЬКИЙ ВМІСТ І ЛІЦЕНЗІЯ",
    text: "Ви зберігаєте право власності на створений або надісланий вами вміст, зокрема відображувані імена, аватари, коментарі та власні набори слів. Ви заявляєте й гарантуєте, що володієте таким вмістом або маєте всі необхідні права для його надсилання та що він не порушує прав третіх осіб. Надсилаючи користувацький вміст, ви надаєте SpyClash всесвітню, невиключну, безоплатну ліцензію з правом субліцензування та передавання на розміщення, зберігання, відтворення, форматування, технічну адаптацію, публічне відображення, повідомлення, розповсюдження, модерацію та інше використання цього вмісту в обсязі, необхідному для роботи, надання, захисту, вдосконалення й просування сервісу. Ця ліцензія діє лише стільки, скільки обґрунтовано потрібно для зазначених цілей, з урахуванням вмісту, уже поширеного серед інших користувачів, резервних копій, законодавчих строків зберігання та записів про застосування правил. Ви можете видаляти вміст там, де передбачено відповідні засоби керування, а ми можемо видаляти вміст, що порушує ці Умови."
  },
  {
    title: "7. СТАНДАРТИ СПІЛЬНОТИ ТА БЕЗПЕКА",
    text: "Не публікуйте переслідування, цькування, мову ворожнечі, погрози, заохочення до самоушкодження, сексуальний чи експлуатаційний вміст, незаконний вміст, спам, матеріали з видаванням себе за іншу особу, приватну інформацію або інші образливі матеріали. Автоматичні серверні фільтри можуть відхиляти неприйнятні матеріали, але жоден фільтр не є бездоганним. Скористайтеся функцією «Поскаржитися» у профілі або коментарі, щоб надіслати приватну скаргу на розгляд модерації. Скористайтеся функцією «Заблокувати», щоб обидва облікові записи не могли знаходити чи відкривати профілі один одного, коментувати або надсилати запрошення до кімнат; наявні між ними коментарі й запрошення буде видалено. Після перевірки ми можемо видалити вміст, обмежити функції, призупинити або видалити облікові записи. Свідомо неправдиві чи образливі скарги також порушують ці Стандарти. Щоб подати запит на перегляд або апеляцію, відвідайте https://spyclash.com/support."
  },
  {
    title: "8. ІНТЕЛЕКТУАЛЬНА ВЛАСНІСТЬ",
    text: "За винятком користувацького вмісту, програмне забезпечення SpyClash, бренд, оригінальні графічні матеріали, функції та можливості належать нам або використовуються за ліцензією й захищені міжнародним законодавством про авторське право, торговельні марки та інші права інтелектуальної власності."
  },
  {
    title: "9. ВІДМОВА ВІД ГАРАНТІЙ",
    text: "SpyClash надається «як є» без будь-яких прямих або неявних гарантій. Ми не гарантуємо, що сервіс працюватиме безперервно, без помилок, вірусів чи інших шкідливих компонентів."
  },
  {
    title: "10. ОБМЕЖЕННЯ ВІДПОВІДАЛЬНОСТІ",
    text: "У максимальному обсязі, дозволеному законом, ми не несемо відповідальності за будь-які непрямі, випадкові, спеціальні, наслідкові або штрафні збитки, що виникли внаслідок використання вами сервісу або пов'язані з ним."
  },
  {
    title: "11. ЗМІНИ ДО УМОВ",
    text: "Ми залишаємо за собою право будь-коли змінювати ці Умови використання. Про суттєві зміни ми повідомимо користувачів, опублікувавши оновлену версію на цій сторінці. Подальше використання сервісу після змін означає прийняття нових умов."
  },
  {
    title: "12. КОНТАКТИ",
    text: "Щоб отримати підтримку або поставити запитання щодо цих Умов, відвідайте https://spyclash.com/support."
  }
];

export default function TermsOfService() {
  const navigate = useNavigate();
  const { lang } = useLanguage();

  return (
    <div style={{ minHeight: "calc(100vh - 80px)", padding: "60px 20px" }}>
      <LanguageSwitcher style={{ position: "fixed", top: 18, right: 18, zIndex: 20 }} />
      <div style={{ maxWidth: 760, margin: "0 auto" }}>
        <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }}>
          <div style={{ fontSize: 10, letterSpacing: 4, color: "#555", marginBottom: 12, textTransform: "uppercase" }}>{localize(lang, "Legal", "Правовая информация", "Правова інформація")}</div>
          <h1 style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 36, letterSpacing: 3, marginBottom: 8, color: "#fff" }}>
            {localize(lang, "TERMS OF SERVICE", "УСЛОВИЯ ИСПОЛЬЗОВАНИЯ", "УМОВИ ВИКОРИСТАННЯ")}
          </h1>
          <div style={{ color: "#444", fontSize: 11, letterSpacing: 2, marginBottom: 48 }}>{localize(lang, "Last updated: July 2026", "Последнее обновление: июль 2026 г.", "Останнє оновлення: липень 2026 р.")}</div>

          <div style={{ display: "flex", flexDirection: "column", gap: 36 }}>
            {(lang === "uk" ? UK_TERMS : [
              {
                title: "1. ACCEPTANCE OF TERMS",
                text: "SpyClash is operated by David Ganzha. By accessing or using SpyClash, you agree to be bound by these Terms of Service. If you do not agree to these terms, please do not use our service."
              },
              {
                title: "2. USE OF THE SERVICE",
                text: "SpyClash is a multiplayer social deduction game intended for entertainment purposes. You must be at least 13 years old to use this service. You agree to use the service only for lawful purposes and in a manner that does not infringe the rights of others."
              },
              {
                title: "3. ACCOUNT RESPONSIBILITY",
                text: "You are responsible for maintaining the confidentiality of your account credentials and for all activities that occur under your account. You agree to notify us immediately of any unauthorized use of your account."
              },
              {
                title: "4. FAIR PLAY",
                text: "You agree to play fairly and not to use any cheats, exploits, automation software, bots, hacks, or any unauthorized third-party software that may affect the gameplay. Violations may result in account suspension or termination."
              },
              {
                title: "5. CONTENT",
                text: "You agree not to use the game to transmit any content that is unlawful, harmful, threatening, abusive, harassing, defamatory, or otherwise objectionable. We reserve the right to remove any content that violates these terms."
              },
              {
                title: "6. USER CONTENT AND LICENSE",
                text: "You retain ownership of content you create or submit, including display names, avatars, comments, and custom word packs. You represent and warrant that you own that content or have every right needed to submit it and that it does not infringe any third party's rights. By submitting user content, you grant SpyClash a worldwide, non-exclusive, royalty-free, sublicensable, and transferable license to host, store, reproduce, format, adapt for technical requirements, publicly display, communicate, distribute, moderate, and otherwise use that content as necessary to operate, provide, secure, improve, and promote the service. This license lasts only as long as reasonably necessary for those purposes, subject to content already shared with other users, backups, legal retention, and enforcement records. You may delete content where controls are provided, and we may remove content that violates these Terms."
              },
              {
                title: "7. COMMUNITY STANDARDS AND SAFETY",
                text: "Do not post harassment, bullying, hate speech, threats, encouragement of self-harm, sexual or exploitative content, illegal content, spam, impersonation, private information, or other abusive material. Automated server filters may reject objectionable submissions, but no filter is perfect. Use Report on a profile or comment to send a private report for moderation review. Use Block to stop both accounts from discovering or opening each other's profiles, commenting, or sending room invitations; existing comments and invitations between the accounts are removed. We may remove content, restrict features, suspend, or terminate accounts after review. Knowingly false or abusive reports also violate these Standards. For a review or appeal request, visit https://spyclash.com/support."
              },
              {
                title: "8. INTELLECTUAL PROPERTY",
                text: "Except for user content, the SpyClash software, brand, original artwork, features, and functionality are owned by us or used under license and are protected by international copyright, trademark, and other intellectual property laws."
              },
              {
                title: "9. DISCLAIMER OF WARRANTIES",
                text: "SpyClash is provided 'as is' without any warranties of any kind, either express or implied. We do not warrant that the service will be uninterrupted, error-free, or free of viruses or other harmful components."
              },
              {
                title: "10. LIMITATION OF LIABILITY",
                text: "To the maximum extent permitted by law, we shall not be liable for any indirect, incidental, special, consequential, or punitive damages arising out of or related to your use of the service."
              },
              {
                title: "11. CHANGES TO TERMS",
                text: "We reserve the right to modify these Terms of Service at any time. We will notify users of significant changes by posting an updated version on this page. Continued use of the service after changes constitutes acceptance of the new terms."
              },
              {
                title: "12. CONTACT",
                text: "For support or questions about these Terms, visit https://spyclash.com/support."
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
