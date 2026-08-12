import { createContext, useContext, useState, useEffect } from "react";
import { base44 } from "@/api/base44Client";
import { getT, normalizeLanguage, translations } from "./i18n";

export const LanguageContext = createContext({
  lang: "en",
  t: getT("en"),
  locale: translations.en,
  setLang: (_newLang, _saveToProfile = false) => {}
});

export function LanguageProvider({ children }) {
  const [lang, setLangState] = useState(() => {
    return normalizeLanguage(localStorage.getItem("spy_lang"));
  });
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const localLang = localStorage.getItem("spy_lang");
    base44.auth.me().then(u => {
      if (u?.language && !localLang) {
        // Only use profile language if user hasn't explicitly set a local preference
        const profileLanguage = normalizeLanguage(u.language);
        setLangState(profileLanguage);
        localStorage.setItem("spy_lang", profileLanguage);
      }
    }).catch(() => {}).finally(() => setReady(true));
  }, []);

  const setLang = (newLang, saveToProfile = false) => {
    const normalized = normalizeLanguage(newLang);
    setLangState(normalized);
    localStorage.setItem("spy_lang", normalized);
    if (saveToProfile) {
      base44.auth.updateMe({ language: normalized }).catch(() => {});
    }
  };

  const t = getT(lang);
  const locale = translations[lang];

  useEffect(() => {
    document.documentElement.lang = lang;
  }, [lang]);

  return (
    <LanguageContext.Provider value={{ lang, t, locale, setLang }}>
      {children}
    </LanguageContext.Provider>
  );
}

export function useLanguage() {
  return useContext(LanguageContext);
}
