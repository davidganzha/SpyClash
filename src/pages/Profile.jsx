import { useEffect, useMemo, useState } from "react";
import { base44 } from "@/api/base44Client";
import { createPageUrl } from "@/utils";
import { useNavigate } from "react-router-dom";
import { motion } from "framer-motion";
import { useLanguage } from "@/components/LanguageContext";
import Reveal from "@/components/Reveal";
import DeleteAccountSection from "@/components/DeleteAccountSection";
import PageChrome from "@/components/PageChrome";
import { loadPlayerGameHistory } from "@/lib/gameHistory";
import {
  ACCOUNT_AVATARS,
  accountAvatarForDisplay,
  resolveAccountAvatarSelection,
} from "@/lib/avatars";

const THEMES = [
  { id: "field", label: "FIELD" },
  { id: "blacksite", label: "BLACKSITE" },
  { id: "dossier", label: "DOSSIER" },
];
const ACCENTS = [
  { id: "signal_red", label: "RED", color: "#e53535" },
  { id: "clearance_amber", label: "AMBER", color: "#fbbf24" },
  { id: "verified_green", label: "GREEN", color: "#4ade80" },
];
const BADGES = [
  { id: "operative", label: "OPERATIVE", symbol: "◆" },
  { id: "ghost", label: "GHOST", symbol: "◌" },
  { id: "analyst", label: "ANALYST", symbol: "⌁" },
  { id: "handler", label: "HANDLER", symbol: "▲" },
];

function SpyCard({
  avatar,
  badge,
  displayName,
  games,
  rating,
  spyID,
  theme,
  accent,
  winRate,
}) {
  const badgeOption = BADGES.find((item) => item.id === badge) || BADGES[0];
  const accentClass = accent === "#fbbf24"
    ? "spycard-accent-amber"
    : accent === "#4ade80"
      ? "spycard-accent-green"
      : "spycard-accent-red";

  return (
    <motion.section
      className={`spycard-preview spycard-preview-${theme} ${accentClass}`}
      initial={{ opacity: 0, y: 22, scale: 0.98 }}
      animate={{ opacity: 1, y: 0, scale: 1 }}
      transition={{ delay: 0.12, duration: 0.5, ease: [0.22, 0.61, 0.36, 1] }}
      aria-label={`SPYCARD ${displayName}`}
    >
      <div className="spycard-pattern" aria-hidden />
      <div className="spycard-topline">
        <span className="spycard-mark">S</span>
        <span className="spycard-clearance">
          <span>{badgeOption.symbol}</span>
          {badgeOption.label}
        </span>
      </div>

      <div className="spycard-identity">
        <div className="spycard-avatar" aria-hidden>{avatar}</div>
        <div>
          <strong>{displayName || "OPERATIVE"}</strong>
          <span>SPYID • {spyID}</span>
        </div>
      </div>

      <div className="spycard-reticle" aria-hidden />
      <div className="spycard-stats">
        <div>
          <strong style={{ color: "#e53535" }}>{rating >= 0 ? `+${rating}` : rating}</strong>
          <span>RATING</span>
        </div>
        <div>
          <strong style={{ color: "#fbbf24" }}>{games}</strong>
          <span>GAMES</span>
        </div>
        <div>
          <strong style={{ color: "#4ade80" }}>{winRate}%</strong>
          <span>RATE</span>
        </div>
      </div>
    </motion.section>
  );
}

function StudioChoice({ active, children, color = "#e53535", onClick }) {
  return (
    <motion.button
      type="button"
      whileTap={{ scale: 0.97 }}
      onClick={onClick}
      style={{
        position: "relative",
        minHeight: 42,
        padding: "9px 10px",
        borderRadius: 16,
        border: `1px solid ${active ? color : "#262626"}`,
        background: active ? `${color}14` : "#0b0b0b",
        color: active ? "#fff" : "#777",
        fontFamily: "'Share Tech Mono', monospace",
        fontSize: 9,
        fontWeight: 700,
        letterSpacing: 1.2,
        cursor: "pointer",
      }}
    >
      {children}
      {active && (
        <span
          aria-hidden
          style={{
            position: "absolute",
            top: -3,
            right: -3,
            width: 15,
            height: 15,
            borderRadius: "50%",
            display: "grid",
            placeItems: "center",
            background: color,
            color: "#050505",
            fontSize: 9,
          }}
        >
          ✓
        </span>
      )}
    </motion.button>
  );
}

export default function Profile() {
  const { t, lang, setLang } = useLanguage();
  const [user, setUser] = useState(null);
  const [displayName, setDisplayName] = useState("");
  const [avatar, setAvatar] = useState(ACCOUNT_AVATARS[0]);
  const [language, setLanguage] = useState("en");
  const [theme, setTheme] = useState("field");
  const [accent, setAccent] = useState("signal_red");
  const [badge, setBadge] = useState("operative");
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState("");
  const [history, setHistory] = useState([]);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const navigate = useNavigate();

  useEffect(() => {
    let cancelled = false;
    setLoadingHistory(true);
    base44.auth.me().then((nextUser) => {
      if (cancelled) return;
      if (!nextUser) {
        base44.auth.redirectToLogin(createPageUrl("Profile"));
        return;
      }

      setUser(nextUser);
      setDisplayName(nextUser.display_name || nextUser.full_name || "");
      setAvatar(accountAvatarForDisplay(nextUser.avatar));
      setLanguage(nextUser.language || "en");
      setTheme(nextUser.spy_card_theme || "field");
      setAccent(nextUser.spy_card_accent || "signal_red");
      setBadge(nextUser.spy_card_badge || "operative");
      loadPlayerGameHistory(nextUser.email, {
        fullHistory: true,
        userId: nextUser.id,
      }).then((items) => {
        if (!cancelled) setHistory(items);
      }).catch(() => {
        if (!cancelled) setHistory([]);
      }).finally(() => {
        if (!cancelled) setLoadingHistory(false);
      });
    }).catch(() => navigate(createPageUrl("Home")));

    return () => {
      cancelled = true;
    };
  }, [navigate]);

  const handleSave = async () => {
    setSaving(true);
    setSaveError("");
    const permittedAvatar = resolveAccountAvatarSelection(avatar, user.avatar);

    try {
      const updates = {
        display_name: displayName,
        avatar: permittedAvatar,
        language,
        spy_card_theme: theme,
        spy_card_accent: accent,
        spy_card_badge: badge,
      };
      const updatedUser = await base44.auth.updateMe(updates);
      setUser(updatedUser || { ...user, ...updates });
      setAvatar(permittedAvatar);
      setLang(language);
    } catch (error) {
      console.error("Profile update failed", error);
      setSaveError(lang === "ru" ? "НЕ УДАЛОСЬ СОХРАНИТЬ ПРОФИЛЬ" : "PROFILE SAVE FAILED");
    } finally {
      setSaving(false);
    }
  };

  const stats = useMemo(() => {
    const wins = history.filter((item) => item.won).length;
    const losses = history.length - wins;
    const winRate = history.length ? Math.round((wins / history.length) * 100) : 0;
    const spyGames = history.filter((item) => item.role === "spy");
    const detectiveGames = history.filter((item) => item.role === "detective");
    const spyWinRate = spyGames.length
      ? Math.round((spyGames.filter((item) => item.won).length / spyGames.length) * 100)
      : 0;
    const detectiveWinRate = detectiveGames.length
      ? Math.round((detectiveGames.filter((item) => item.won).length / detectiveGames.length) * 100)
      : 0;

    return {
      wins,
      losses,
      winRate,
      cards: [
        { label: t("profile_missions"), value: history.length, color: "#fff" },
        { label: t("profile_wins"), value: wins, color: "#4ade80" },
        { label: lang === "ru" ? "ПРОЦЕНТ ПОБЕД" : "WIN RATE", value: `${winRate}%`, color: "#4ade80" },
        { label: lang === "ru" ? "ШПИОН" : "SPY WIN RATE", value: `${spyWinRate}%`, color: "#e53535" },
        { label: lang === "ru" ? "ДЕТЕКТИВ" : "DETECTIVE WIN RATE", value: `${detectiveWinRate}%`, color: "#60a5fa" },
        { label: t("profile_losses"), value: losses, color: "#e53535" },
      ],
    };
  }, [history, lang, t]);

  if (!user) return null;

  const accentColor = ACCENTS.find((item) => item.id === accent)?.color || "#e53535";
  const spyID = user.spy_id || "000-000";
  const rating = Number.isFinite(Number(user.rating))
    ? Number(user.rating)
    : stats.wins * 50;

  return (
    <PageChrome eyebrow="// PROFILE" status="">
      <style>{`
        .profile-ios-page { width:min(100%,680px); margin:0 auto; padding:20px 16px 34px; }
        .spycard-accent-red { --spycard-accent:#e53535; }
        .spycard-accent-amber { --spycard-accent:#fbbf24; }
        .spycard-accent-green { --spycard-accent:#4ade80; }
        .spycard-preview { position:relative; min-height:226px; overflow:hidden; margin-bottom:16px; padding:15px 17px 18px; border:1px solid color-mix(in srgb,var(--spycard-accent) 35%,#292929); border-radius:22px; background:linear-gradient(135deg,#201d1e 0%,#161415 48%,#251819 100%); box-shadow:0 14px 34px rgba(0,0,0,.34),inset 0 1px rgba(255,255,255,.08); }
        .spycard-preview-blacksite { background:linear-gradient(145deg,#080808,#171719 60%,#090909); }
        .spycard-preview-dossier { background:linear-gradient(145deg,#281312,#161010 55%,#211715); }
        .spycard-pattern { position:absolute; inset:0; opacity:.44; background-image:linear-gradient(rgba(255,255,255,.025) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.02) 1px,transparent 1px),radial-gradient(circle at 79% 74%,transparent 0 22px,color-mix(in srgb,var(--spycard-accent) 20%,transparent) 23px 24px,transparent 25px); background-size:42px 42px,42px 42px,100% 100%; pointer-events:none; }
        .spycard-topline,.spycard-identity,.spycard-stats { position:relative; z-index:1; }
        .spycard-topline { display:flex; align-items:center; gap:9px; }
        .spycard-mark { color:var(--spycard-accent); font-family:'Rajdhani',sans-serif; font-size:25px; font-weight:700; font-style:italic; }
        .spycard-clearance { display:inline-flex; align-items:center; gap:6px; min-height:22px; padding:0 10px; border-radius:11px; border:1px solid color-mix(in srgb,var(--spycard-accent) 35%,transparent); background:color-mix(in srgb,var(--spycard-accent) 11%,transparent); color:#ddd; font-size:8px; font-weight:700; letter-spacing:1.2px; }
        .spycard-identity { display:flex; align-items:center; gap:13px; margin-top:20px; }
        .spycard-avatar { width:50px; height:50px; display:grid; place-items:center; border-radius:10px; border:1px solid color-mix(in srgb,var(--spycard-accent) 45%,#292929); background:#0b0b0b; font-size:26px; }
        .spycard-identity strong { display:block; font-family:'Rajdhani',sans-serif; font-size:20px; letter-spacing:2px; }
        .spycard-identity span { display:block; margin-top:4px; color:#696969; font-size:8px; letter-spacing:1.2px; }
        .spycard-reticle { position:absolute; right:31px; bottom:45px; width:32px; height:32px; border:1px solid color-mix(in srgb,var(--spycard-accent) 20%,transparent); border-radius:50%; opacity:.45; }
        .spycard-reticle::before,.spycard-reticle::after { content:''; position:absolute; background:color-mix(in srgb,var(--spycard-accent) 20%,transparent); }
        .spycard-reticle::before { width:46px; height:1px; left:-8px; top:15px; }
        .spycard-reticle::after { width:1px; height:46px; top:-8px; left:15px; }
        .spycard-stats { display:flex; justify-content:flex-end; gap:28px; margin-top:54px; padding-right:13px; }
        .spycard-stats div { text-align:center; min-width:38px; }
        .spycard-stats strong { display:block; font-family:'Rajdhani',sans-serif; font-size:18px; letter-spacing:.5px; }
        .spycard-stats span { display:block; margin-top:2px; color:#555; font-size:6px; letter-spacing:1px; }
        .profile-settings { position:relative; padding:17px 16px 19px; margin-bottom:16px; border:1px solid #202020; background:rgba(10,10,10,.92); clip-path:polygon(0 0,calc(100% - 12px) 0,100% 12px,100% 100%,12px 100%,0 calc(100% - 12px)); }
        .profile-settings::before { content:''; position:absolute; top:-1px; left:-1px; width:18px; height:1px; background:#e53535; }
        .profile-kicker { margin-bottom:13px; color:#555; font-size:9px; letter-spacing:2px; }
        .profile-avatar-grid { display:flex; flex-wrap:wrap; gap:8px; margin-bottom:18px; }
        .profile-avatar-button { width:39px; height:39px; display:grid; place-items:center; border:1px solid #202020; background:#080808; font-size:21px; cursor:pointer; }
        .profile-studio-grid { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:6px; margin-bottom:14px; }
        .profile-badge-grid { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:6px; margin-bottom:18px; }
        .profile-form-grid { display:grid; grid-template-columns:1fr 150px; gap:10px; align-items:end; }
        .profile-actions { display:flex; gap:10px; margin-top:12px; }
        .profile-actions > button { flex:1; min-height:48px; }
        @media (max-width:560px) {
          .profile-ios-page { padding-inline:14px; }
          .profile-form-grid { grid-template-columns:1fr; }
          .profile-badge-grid { grid-template-columns:repeat(2,minmax(0,1fr)); }
          .spycard-stats { gap:17px; padding-right:0; }
        }
      `}</style>

      <main className="profile-ios-page">
        <SpyCard
          avatar={avatar}
          badge={badge}
          displayName={String(displayName || "OPERATIVE").toUpperCase()}
          games={history.length}
          rating={rating}
          spyID={spyID}
          theme={theme}
          accent={accentColor}
          winRate={stats.winRate}
        />

        <motion.section
          className="profile-settings"
          initial={{ opacity: 0, y: 18 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.22, duration: 0.45 }}
        >
          <div className="profile-kicker">// {lang === "ru" ? "НАСТРОЙКИ ЛИЧНОСТИ" : "IDENTITY SETTINGS"}</div>
          <div className="profile-kicker">// {t("profile_select_avatar")}</div>
          <div className="profile-avatar-grid">
            {(ACCOUNT_AVATARS.includes(avatar) ? ACCOUNT_AVATARS : [avatar, ...ACCOUNT_AVATARS]).map((item, index) => (
              <motion.button
                key={item}
                type="button"
                className="profile-avatar-button"
                initial={{ opacity: 0, scale: 0.82 }}
                animate={{ opacity: 1, scale: 1 }}
                transition={{ delay: 0.22 + index * 0.025 }}
                whileTap={{ scale: 0.9 }}
                onClick={() => setAvatar(item)}
                aria-label={`Avatar ${item}`}
                style={{
                  borderColor: avatar === item ? "#e53535" : "#202020",
                  background: avatar === item ? "rgba(229,53,53,.1)" : "#080808",
                  boxShadow: avatar === item ? "0 0 12px rgba(229,53,53,.18)" : "none",
                }}
              >
                {item}
              </motion.button>
            ))}
          </div>

          <div className="profile-kicker">// SPYCARD STUDIO</div>
          <div className="profile-kicker" style={{ marginBottom: 7 }}>SKIN</div>
          <div className="profile-studio-grid">
            {THEMES.map((item) => (
              <StudioChoice key={item.id} active={theme === item.id} onClick={() => setTheme(item.id)}>
                {item.label}
              </StudioChoice>
            ))}
          </div>

          <div className="profile-kicker" style={{ marginBottom: 7 }}>SIGNAL</div>
          <div className="profile-studio-grid">
            {ACCENTS.map((item) => (
              <StudioChoice
                key={item.id}
                active={accent === item.id}
                color={item.color}
                onClick={() => setAccent(item.id)}
              >
                <span style={{ color: item.color, marginRight: 6 }}>●</span>
                {item.label}
              </StudioChoice>
            ))}
          </div>

          <div className="profile-kicker" style={{ marginBottom: 7 }}>CLEARANCE</div>
          <div className="profile-badge-grid">
            {BADGES.map((item) => (
              <StudioChoice
                key={item.id}
                active={badge === item.id}
                color={accentColor}
                onClick={() => setBadge(item.id)}
              >
                <span style={{ marginRight: 5 }}>{item.symbol}</span>
                {item.label}
              </StudioChoice>
            ))}
          </div>

          {saveError && (
            <div style={{ color: "#e53535", fontSize: 9, letterSpacing: 1.7, marginBottom: 12 }}>
              {saveError}
            </div>
          )}

          <div className="profile-form-grid">
            <label>
              <span className="profile-kicker" style={{ display: "block", marginBottom: 7 }}>
                // {t("profile_display_name")}
              </span>
              <input
                value={displayName}
                onChange={(event) => setDisplayName(event.target.value)}
                placeholder={t("profile_name_placeholder")}
                maxLength={30}
                style={{ minHeight: 46, letterSpacing: 2, textTransform: "uppercase" }}
              />
            </label>
            <label>
              <span className="profile-kicker" style={{ display: "block", marginBottom: 7 }}>
                // {t("profile_language")}
              </span>
              <select
                value={language}
                onChange={(event) => setLanguage(event.target.value)}
                style={{ minHeight: 46 }}
              >
                <option value="en">ENGLISH</option>
                <option value="ru">РУССКИЙ</option>
                <option value="es">ESPAÑOL</option>
              </select>
            </label>
          </div>

          <div className="profile-actions">
            <motion.button
              whileTap={{ scale: 0.98 }}
              className="btn-red"
              onClick={handleSave}
              disabled={saving}
            >
              {saving ? t("profile_saving") : t("profile_save")}
            </motion.button>
            <motion.button
              whileTap={{ scale: 0.98 }}
              className="btn-ghost"
              onClick={() => {
                try {
                  localStorage.removeItem("base44_access_token");
                  localStorage.removeItem("token");
                } catch {}
                base44.auth.logout(createPageUrl("Home"));
              }}
            >
              {t("profile_logout")}
            </motion.button>
          </div>
        </motion.section>

        <Reveal delay={0}>
          <section
            style={{
              display: "grid",
              gridTemplateColumns: "repeat(auto-fit,minmax(145px,1fr))",
              gap: 1,
              marginBottom: 16,
              background: "#111",
            }}
          >
            {stats.cards.map((item, index) => (
              <motion.div
                key={item.label}
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                transition={{ delay: 0.28 + index * 0.05 }}
                style={{ background: "#0a0a0a", padding: "20px 16px", textAlign: "center" }}
              >
                <strong
                  style={{
                    display: "block",
                    color: item.color,
                    fontFamily: "'Rajdhani',sans-serif",
                    fontSize: 30,
                    letterSpacing: 1.5,
                  }}
                >
                  {item.value}
                </strong>
                <span style={{ display: "block", marginTop: 3, color: "#444", fontSize: 8, letterSpacing: 2 }}>
                  {String(item.label).toUpperCase()}
                </span>
              </motion.div>
            ))}
          </section>
        </Reveal>

        <Reveal delay={80}>
          <section>
            <div className="profile-kicker">{t("profile_recent")}</div>
            <div style={{ display: "flex", flexDirection: "column", gap: 6, marginBottom: 16 }}>
              {loadingHistory ? (
                <motion.div
                  animate={{ opacity: [0.3, 1, 0.3] }}
                  transition={{ duration: 1.5, repeat: Infinity }}
                  style={{ color: "#444", textAlign: "center", padding: 24, fontSize: 10, letterSpacing: 2 }}
                >
                  {t("profile_loading")}
                </motion.div>
              ) : history.length === 0 ? (
                <div style={{ color: "#444", textAlign: "center", padding: 24, fontSize: 10, letterSpacing: 2 }}>
                  {t("profile_no_missions")}
                </div>
              ) : history.slice(0, 5).map((item, index) => (
                <motion.div
                  key={item.id}
                  initial={{ opacity: 0, x: -12 }}
                  animate={{ opacity: 1, x: 0 }}
                  transition={{ delay: index * 0.04 }}
                  style={{
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "space-between",
                    gap: 12,
                    padding: "10px 14px",
                    background: "#080808",
                    border: "1px solid #171717",
                  }}
                >
                  <div>
                    <div style={{ color: "#ccc", fontSize: 11, letterSpacing: 1, marginBottom: 3 }}>
                      {item.role === "spy" ? t("history_spy") : t("history_detective")} —{" "}
                      <span style={{ color: "#e53535" }}>{item.word || "?"}</span>
                    </div>
                    <div style={{ color: "#3f3f3f", fontSize: 8, letterSpacing: 1.5 }}>
                      {item.category?.toUpperCase()} · {item.player_count}P
                    </div>
                  </div>
                  <div
                    style={{
                      padding: "3px 9px",
                      border: `1px solid ${item.won ? "rgba(74,222,128,.25)" : "rgba(229,53,53,.25)"}`,
                      background: item.won ? "rgba(74,222,128,.08)" : "rgba(229,53,53,.08)",
                      color: item.won ? "#4ade80" : "#e53535",
                      fontSize: 9,
                      fontWeight: 700,
                      letterSpacing: 1.5,
                    }}
                  >
                    {item.won ? t("profile_win") : t("profile_loss")}
                  </div>
                </motion.div>
              ))}
            </div>

            <a href={createPageUrl("History")} style={{ display: "block", textDecoration: "none" }}>
              <button className="btn-outline" style={{ width: "100%", minHeight: 46, fontSize: 10 }}>
                {t("profile_view_history")}
              </button>
            </a>
          </section>
        </Reveal>

        <DeleteAccountSection />
      </main>
    </PageChrome>
  );
}
