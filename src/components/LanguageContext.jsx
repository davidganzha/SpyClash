import { createContext, useContext, useState, useEffect } from "react";
import { base44 } from "@/api/base44Client";
import { getT, translations } from "./i18n";

export const LanguageContext = createContext({
  lang: "en",
  t: getT("en"),
  locale: translations.en,
  setLang: (_newLang, _saveToProfile = false) => {}
});

export function LanguageProvider({ children }) {
  const [lang, setLangState] = useState(() => {
    return localStorage.getItem("spy_lang") || "en";
  });
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const localLang = localStorage.getItem("spy_lang");
    base44.auth.me().then(u => {
      if (u?.language && !localLang) {
        // Only use profile language if user hasn't explicitly set a local preference
        setLangState(u.language);
        localStorage.setItem("spy_lang", u.language);
      }
    }).catch(() => {}).finally(() => setReady(true));
  }, []);

  const setLang = (newLang, saveToProfile = false) => {
    setLangState(newLang);
    localStorage.setItem("spy_lang", newLang);
    if (saveToProfile) {
      base44.auth.updateMe({ language: newLang }).catch(() => {});
    }
  };

  const t = getT(lang);
  const locale = translations[lang] || translations.en;



  return (
    <LanguageContext.Provider value={{ lang, t, locale, setLang }}>
      {children}
    </LanguageContext.Provider>
  );
}

export function useLanguage() {
  return useContext(LanguageContext);
}
