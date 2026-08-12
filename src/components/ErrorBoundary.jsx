import { Component } from "react";
import { localize, normalizeLanguage } from "@/components/i18n";

export default class ErrorBoundary extends Component {
  constructor(props) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error) {
    return { hasError: true, error };
  }

  componentDidCatch(error, info) {
    console.error("ErrorBoundary caught:", error, info);
  }

  render() {
    if (this.state.hasError) {
      const lang = normalizeLanguage(localStorage.getItem("spy_lang"));
      return (
        <div style={{
          position: "fixed", inset: 0, background: "#000",
          display: "flex", flexDirection: "column",
          alignItems: "center", justifyContent: "center",
          fontFamily: "monospace", padding: 24
        }}>
          <div style={{ color: "#e53535", fontSize: 28, marginBottom: 16 }}>⚠</div>
          <div style={{ color: "#888", fontSize: 12, letterSpacing: 3, marginBottom: 12 }}>{localize(lang, "APP CRASH", "СБОЙ ПРИЛОЖЕНИЯ", "ЗБІЙ ЗАСТОСУНКУ")}</div>
          <div style={{
            color: "#444", fontSize: 11, letterSpacing: 1, marginBottom: 24,
            maxWidth: 480, textAlign: "center", lineHeight: 1.6,
            wordBreak: "break-all"
          }}>
            {this.state.error?.message || localize(lang, "Unknown error", "Неизвестная ошибка", "Невідома помилка")}
          </div>
          <button
            onClick={() => window.location.reload()}
            style={{
              background: "#e53535", color: "#fff", border: "none",
              padding: "10px 28px", fontSize: 12, letterSpacing: 3,
              fontFamily: "monospace", cursor: "pointer"
            }}
          >{localize(lang, "RETRY", "ПОВТОРИТЬ", "ПОВТОРИТИ")}</button>
        </div>
      );
    }
    return this.props.children;
  }
}
