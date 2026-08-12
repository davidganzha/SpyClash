import { motion } from "framer-motion";
import { Link, useNavigate } from "react-router-dom";
import Reveal from "@/components/Reveal";
import { createPageUrl } from "@/utils";
import LanguageSwitcher from "@/components/LanguageSwitcher";
import { useLanguage } from "@/components/LanguageContext";

const DEFAULT_SUPPORT_EMAIL = "yanushevych.mr@gmail.com";
const supportEmail = String(
  document.querySelector('meta[name="spyclash-support-email"]')?.getAttribute("content")
  || DEFAULT_SUPPORT_EMAIL
).trim();

const SUPPORT_COPY = {
  en: {
    eyebrow: "Support",
    title: "SPYCLASH SUPPORT",
    intro: "Include your Spy ID, device model, iOS version, and a short description of the problem. Never send passwords, payment-card details, or Apple verification codes.",
    contact: "CONTACT",
    email: "EMAIL",
    privacy: "PRIVACY POLICY",
    terms: "TERMS",
    back: "← BACK TO HOME",
    subject: "SpyClash support request",
    topics: [
      { title: "ROOM OR QR PROBLEMS", text: "Confirm that every player is using the current SpyClash version. The host can share the six-character room code when camera access or QR scanning is unavailable." },
      { title: "DELETE YOUR ACCOUNT", text: "In the iOS app, open Profile, scroll to DANGER ZONE, and choose DELETE ACCOUNT. Profile data, saved word packs, and match history are removed; limited transaction records may be retained for legal, accounting, and fraud-prevention obligations." },
      { title: "REPORT OR BLOCK COMMUNITY ABUSE", text: "Open the operative's Community profile to report the account or block it. Individual profile-wall comments also have a Report control. Reports are private and placed in an administrator-only moderation queue. Blocking prevents both accounts from finding or contacting each other in Community and removes their existing comments and room invitations. Include your Spy ID and the approximate time of the incident if you contact support for a review or appeal." }
    ]
  },
  ru: {
    eyebrow: "Поддержка",
    title: "ПОДДЕРЖКА SPYCLASH",
    intro: "Укажите свой Spy ID, модель устройства, версию iOS и кратко опишите проблему. Никогда не отправляйте пароли, данные платёжной карты или коды подтверждения Apple.",
    contact: "СВЯЗАТЬСЯ",
    email: "НАПИСАТЬ",
    privacy: "КОНФИДЕНЦИАЛЬНОСТЬ",
    terms: "УСЛОВИЯ",
    back: "← НА ГЛАВНУЮ",
    subject: "Запрос в поддержку SpyClash",
    topics: [
      { title: "ПРОБЛЕМЫ С КОМНАТОЙ ИЛИ QR", text: "Убедитесь, что все игроки используют актуальную версию SpyClash. Если доступ к камере или сканирование QR недоступны, ведущий может отправить шестизначный код комнаты." },
      { title: "УДАЛЕНИЕ АККАУНТА", text: "В приложении для iOS откройте «Профиль», прокрутите до раздела «Опасная зона» и выберите «Удалить аккаунт». Данные профиля, сохранённые наборы слов и история матчей будут удалены; ограниченные сведения о транзакциях могут храниться для выполнения юридических и бухгалтерских обязанностей и предотвращения мошенничества." },
      { title: "ЖАЛОБА ИЛИ БЛОКИРОВКА В СООБЩЕСТВЕ", text: "Откройте профиль оперативника в Сообществе, чтобы пожаловаться на аккаунт или заблокировать его. На отдельные комментарии на стене профиля также можно пожаловаться. Жалобы конфиденциальны и попадают в доступную только администраторам очередь модерации. Блокировка не позволяет двум аккаунтам находить друг друга и связываться в Сообществе, а также удаляет существующие комментарии и приглашения в комнаты между ними. При обращении в поддержку для пересмотра решения или апелляции укажите свой Spy ID и примерное время инцидента." }
    ]
  },
  uk: {
    eyebrow: "Підтримка",
    title: "ПІДТРИМКА SPYCLASH",
    intro: "Укажіть свій Spy ID, модель пристрою, версію iOS і коротко опишіть проблему. Ніколи не надсилайте паролі, дані платіжної картки або коди підтвердження Apple.",
    contact: "ЗВ'ЯЗАТИСЯ",
    email: "НАПИСАТИ",
    privacy: "КОНФІДЕНЦІЙНІСТЬ",
    terms: "УМОВИ",
    back: "← НА ГОЛОВНУ",
    subject: "Запит до служби підтримки SpyClash",
    topics: [
      { title: "ПРОБЛЕМИ З КІМНАТОЮ АБО QR-КОДОМ", text: "Переконайтеся, що всі гравці використовують актуальну версію SpyClash. Якщо доступ до камери або сканування QR-коду недоступні, ведучий може надіслати шестизначний код кімнати." },
      { title: "ВИДАЛЕННЯ ОБЛІКОВОГО ЗАПИСУ", text: "У застосунку для iOS відкрийте «Профіль», прокрутіть до розділу «Небезпечна зона» й виберіть «Видалити обліковий запис». Дані профілю, збережені набори слів та історію матчів буде видалено; обмежені відомості про транзакції можуть зберігатися для виконання юридичних і бухгалтерських зобов'язань та запобігання шахрайству." },
      { title: "СКАРГА АБО БЛОКУВАННЯ В СПІЛЬНОТІ", text: "Відкрийте профіль оперативника в Спільноті, щоб поскаржитися на обліковий запис або заблокувати його. На окремі коментарі на стіні профілю також можна поскаржитися. Скарги конфіденційні й потрапляють до доступної лише адміністраторам черги модерації. Блокування не дає двом обліковим записам знаходити один одного та зв'язуватися у Спільноті, а також видаляє наявні між ними коментарі й запрошення до кімнат. Звертаючись до підтримки для перегляду рішення або апеляції, укажіть свій Spy ID і приблизний час інциденту." }
    ]
  }
};

export default function Support() {
  const navigate = useNavigate();
  const { lang } = useLanguage();
  const copy = SUPPORT_COPY[lang] || SUPPORT_COPY.en;
  const subject = encodeURIComponent(copy.subject);

  return (
    <div style={{ minHeight: "100vh", padding: "60px 20px", background: "#000" }}>
      <LanguageSwitcher style={{ position: "fixed", top: 18, right: 18, zIndex: 20 }} />
      <div style={{ maxWidth: 760, margin: "0 auto" }}>
        <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }}>
          <div style={{ fontSize: 10, letterSpacing: 4, color: "#555", marginBottom: 12, textTransform: "uppercase" }}>{copy.eyebrow}</div>
          <h1 style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 36, letterSpacing: 3, marginBottom: 8, color: "#fff" }}>
            {copy.title}
          </h1>
          <p style={{ color: "#777", fontSize: 13, lineHeight: 1.8, marginBottom: 36 }}>
            {copy.intro}
          </p>

          <div style={{ display: "flex", flexDirection: "column", gap: 30 }}>
            {copy.topics.map((topic, index) => (
              <Reveal key={topic.title} delay={index * 30}>
                <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 14, letterSpacing: 2.5, color: "#e53535", marginBottom: 8 }}>
                  {topic.title}
                </div>
                <div style={{ color: "#888", fontSize: 13, lineHeight: 1.8 }}>{topic.text}</div>
              </Reveal>
            ))}
          </div>

          <div style={{ marginTop: 42, padding: 24, border: "1px solid #242424", background: "#080808" }}>
            <div style={{ color: "#fff", fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, letterSpacing: 2, marginBottom: 12 }}>
              {copy.contact}
            </div>
            <a className="btn-primary" href={`mailto:${supportEmail}?subject=${subject}`} style={{ display: "inline-flex", textDecoration: "none" }}>
              {copy.email} {supportEmail.toUpperCase()}
            </a>
          </div>

          <div style={{ display: "flex", flexWrap: "wrap", gap: 16, marginTop: 28, fontSize: 11, letterSpacing: 1.4 }}>
            <Link to="/privacypolicy" style={{ color: "#aaa" }}>{copy.privacy}</Link>
            <Link to="/termsofservice" style={{ color: "#aaa" }}>{copy.terms}</Link>
          </div>

          <div style={{ marginTop: 52, paddingTop: 24, borderTop: "1px solid #1a1a1a" }}>
            <button className="btn-ghost" style={{ fontSize: 11 }} onClick={() => navigate(createPageUrl("Home"))}>
              {copy.back}
            </button>
          </div>
        </motion.div>
      </div>
    </div>
  );
}
