import { useState, useEffect } from "react";
import { base44 } from "@/api/base44Client";
import { Link } from "react-router-dom";
import { createPageUrl } from "@/utils";
import { useLanguage } from "@/components/LanguageContext";
import { listWordPacks } from "@/lib/wordPackActions";

export default function WordPackSelector({ onSelect, selectedPackId }) {
  const { t } = useLanguage();
  const [packs, setPacks] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    base44.auth.me().then((u) => {
      if (!u) return;
      listWordPacks().then((all) => {
        setPacks(all);
        setLoading(false);
      });
    }).catch(() => setLoading(false));
  }, []);

  const selected = packs.find((p) => p.id === selectedPackId);

  return (
    <div style={{ marginBottom: 10 }}>
      

      {loading ?
      <div style={{ fontSize: 11, color: "#444", letterSpacing: 1, fontFamily: "monospace", marginBottom: 10 }}>{t('loading')}</div> :
      packs.length === 0 ?
      <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "12px 14px", background: "#080808", border: "1px solid #1a1a1a", marginBottom: 10 }}>
          <span style={{ fontSize: 20 }}>📦</span>
          <div>
            <div style={{ fontSize: 11, color: "#555", letterSpacing: 0.5, marginBottom: 4 }}>{t('wp_page_empty')}</div>
            <Link to={createPageUrl("WordPacks")} style={{ color: "#e53535", textDecoration: "none", fontSize: 11, letterSpacing: 1, fontFamily: "monospace" }}>
              {t('wp_page_create_first')} →
            </Link>
          </div>
        </div> :

      <div style={{ fontSize: 11, color: "#555", letterSpacing: 1, fontFamily: "monospace", marginBottom: 10 }}>
          {t('wp_selector_packs')} <strong style={{ color: "#888" }}>{packs.length}</strong>
        </div>
      }

      {packs.length > 0 &&
      <>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
            <button
            onClick={() => onSelect(null)}
            style={{ padding: "6px 12px", fontSize: 11, letterSpacing: 1, fontFamily: "monospace", cursor: "pointer",
              background: !selectedPackId ? "rgba(229,53,53,0.1)" : "#080808",
              border: `1px solid ${!selectedPackId ? "rgba(229,53,53,0.4)" : "#1a1a1a"}`,
              color: !selectedPackId ? "#e53535" : "#555" }}>
              {t('wp_selector_random')}
            </button>
            {packs.map((p) =>
          <button key={p.id}
          onClick={() => onSelect(p.id)}
          style={{ padding: "6px 12px", fontSize: 11, letterSpacing: 1, fontFamily: "monospace", cursor: "pointer",
            background: selectedPackId === p.id ? "rgba(229,53,53,0.1)" : "#080808",
            border: `1px solid ${selectedPackId === p.id ? "rgba(229,53,53,0.4)" : "#1a1a1a"}`,
            color: selectedPackId === p.id ? "#e53535" : "#888" }}>
                {p.name} <span style={{ color: "#444" }}>({(p.words || []).length})</span>
              </button>
          )}
          </div>
          {selected &&
        <div style={{ marginTop: 8, fontSize: 10, color: "#555", letterSpacing: 1 }}>
              {t('wp_selector_selected')} <strong style={{ color: "#888" }}>{selected.name}</strong> · {selected.words?.length} {t('wp_page_words_count')} · {selected.category || selected.name}
            </div>
        }
        </>
      }
    </div>);

}
