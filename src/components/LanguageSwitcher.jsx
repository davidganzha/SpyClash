import { useLanguage } from "@/components/LanguageContext";
import { localize } from "@/components/i18n";

const languages = [
  { code: "en", label: "EN" },
  { code: "ru", label: "RU" },
  { code: "uk", label: "UK" },
  { code: "es", label: "ES" },
];

export default function LanguageSwitcher({ style = undefined }) {
  const { lang, setLang } = useLanguage();
  const accessibilityLabel = localize(lang, "Choose language", "Выбрать язык", "Обрати мову", "Elegir idioma");

  return (
    <div
      role="group"
      aria-label={accessibilityLabel}
      style={{
        display: "flex",
        gap: 5,
        padding: 4,
        border: "1px solid rgba(255,255,255,0.08)",
        background: "rgba(0,0,0,0.62)",
        backdropFilter: "blur(12px)",
        ...style,
      }}
    >
      {languages.map(({ code, label }) => {
        const active = lang === code;
        return (
          <button
            key={code}
            type="button"
            onClick={() => setLang(code, false)}
            aria-pressed={active}
            style={{
              minWidth: 34,
              minHeight: 28,
              padding: "5px 8px",
              border: `1px solid ${active ? "#e53535" : "transparent"}`,
              background: active ? "rgba(229,53,53,0.16)" : "transparent",
              color: active ? "#fff" : "#666",
              cursor: "pointer",
              fontFamily: "'Share Tech Mono', monospace",
              fontSize: 10,
              fontWeight: 700,
              letterSpacing: 1,
            }}
          >
            {label}
          </button>
        );
      })}
    </div>
  );
}
