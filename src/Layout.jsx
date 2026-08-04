import { Link, useNavigate } from "react-router-dom";
import { createPageUrl } from "@/utils";
import { base44 } from "@/api/base44Client";
import { useEffect, useState, useRef, useCallback } from "react";
import { motion, useMotionValue, useTransform, useMotionValueEvent, animate } from "framer-motion";
import { ChevronUp } from "lucide-react";
import { LanguageProvider, LanguageContext } from "@/components/LanguageContext";
import AppLoader from "@/components/AppLoader";
import PWAInstallPrompt from "@/components/PWAInstallPrompt";
import MenuToggleButton from "@/components/MenuToggleButton";
import { useAuth } from "@/lib/AuthContext";
import { useCommunity } from "@/lib/CommunityContext";

// Один элемент меню — собственный компонент, чтобы useTransform был корректным хуком (не внутри map)
function MenuItem({ progress, idx, totalItems, ITEM_H, children }) {
  const itemP = useTransform(progress, p => Math.min(1, Math.max(0, p * totalItems - idx)));
  const height = useTransform(itemP, p => `${p * ITEM_H}px`);
  const x = useTransform(itemP, p => `${(1 - p) * -20}px`);
  return (
    <motion.div style={{ overflow: "hidden", height, opacity: itemP, x, willChange: "height, opacity, transform" }}>
      {children}
    </motion.div>
  );
}

function DividerItem({ progress, idx, totalItems }) {
  const itemP = useTransform(progress, p => Math.min(1, Math.max(0, p * totalItems - idx)));
  const height = useTransform(itemP, p => `${p * 17}px`);
  return (
    <motion.div style={{ overflow: "hidden", height, opacity: itemP, willChange: "height, opacity" }}>
      <div style={{ borderTop: "1px solid #181818", margin: "8px 16px" }} />
    </motion.div>
  );
}

function MenuContent({ user, currentPageName, setMenuOpen, lang, setLang, t, progress }) {
  const { attentionCount } = useCommunity();
  const menuItems = user ? [
    { icon: "👤", label: t('nav_menu_profile'), page: "Profile" },
    { icon: "🪪", label: t('nav_menu_community'), page: "Community", badge: attentionCount },
    { icon: "📦", label: t('nav_menu_packs'), page: "WordPacks" },
  ] : [];

  const ITEM_H = 40;
  const totalItems = menuItems.length + 2; // divider + logout

  // Footer opacity & transform via motion value
  const footerOpacity = useTransform(progress, p => Math.min(1, Math.max(0, (p - 0.7) / 0.3)));
  const footerY = useTransform(footerOpacity, o => `${(1 - o) * 10}px`);

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "center", padding: "0 24px", gap: 0 }}>

        {menuItems.map((item, i) => (
          <MenuItem key={item.page} progress={progress} idx={i} totalItems={totalItems} ITEM_H={ITEM_H}>
            <Link to={createPageUrl(item.page)} style={{ textDecoration: "none" }} onClick={() => setMenuOpen(false)}>
              <div style={{
                display: "flex", alignItems: "center", gap: 12, padding: "10px 16px",
                height: ITEM_H,
                color: currentPageName === item.page ? "#e53535" : "#bbb",
                fontSize: 13, letterSpacing: 3, fontFamily: "'Share Tech Mono', monospace",
                borderLeft: currentPageName === item.page ? "2px solid #e53535" : "2px solid transparent",
                cursor: "pointer",
              }}
                onMouseEnter={e => { e.currentTarget.style.background = "#111"; e.currentTarget.style.borderLeftColor = "#e53535"; }}
                onMouseLeave={e => { e.currentTarget.style.background = "transparent"; e.currentTarget.style.borderLeftColor = currentPageName === item.page ? "#e53535" : "transparent"; }}
              >
                <span style={{ fontSize: 20, width: 28 }}>{item.icon}</span>
                <span>{item.label}</span>
                {item.badge > 0 && (
                  <span style={{
                    marginLeft: "auto",
                    minWidth: 19,
                    height: 19,
                    padding: "0 5px",
                    borderRadius: 10,
                    display: "grid",
                    placeItems: "center",
                    background: "#e53535",
                    color: "#fff",
                    fontSize: 9,
                    letterSpacing: 0,
                  }}>
                    {item.badge > 99 ? "99+" : item.badge}
                  </span>
                )}
              </div>
            </Link>
          </MenuItem>
        ))}

        {user && <DividerItem progress={progress} idx={menuItems.length} totalItems={totalItems} />}

        {user && (
          <MenuItem progress={progress} idx={menuItems.length + 1} totalItems={totalItems} ITEM_H={ITEM_H}>
            <button
              onClick={() => {
                try {
                  localStorage.removeItem('base44_access_token');
                  localStorage.removeItem('token');
                } catch {}
                setMenuOpen(false);
                base44.auth.logout();
              }}
              style={{
                width: "100%", height: ITEM_H, padding: "0 16px", cursor: "pointer",
                background: "transparent", border: "none", borderLeft: "2px solid transparent",
                color: "#e53535", fontSize: 13, letterSpacing: 3,
                fontFamily: "'Share Tech Mono', monospace",
                textAlign: "left", display: "flex", alignItems: "center", gap: 16
              }}
              onMouseEnter={e => { e.currentTarget.style.background = "#111"; e.currentTarget.style.borderLeftColor = "#e53535"; }}
              onMouseLeave={e => { e.currentTarget.style.background = "transparent"; e.currentTarget.style.borderLeftColor = "transparent"; }}
            >
              <span style={{ fontSize: 20, width: 28 }}>🚪</span> {t('nav_logout')}
            </button>
          </MenuItem>
        )}
      </div>

      {/* Language section — opacity via motion value */}
      <motion.div style={{
        padding: "10px 24px 24px 24px",
        borderTop: "1px solid #141414",
        display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12,
        opacity: footerOpacity,
        y: footerY,
        willChange: "opacity, transform",
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
          <span style={{ fontSize: 10, letterSpacing: 2, color: "#444", fontFamily: "'Share Tech Mono', monospace" }}>{t('nav_menu_lang')}</span>
          <div style={{ display: "flex", gap: 6 }}>
            {[{ code: "en", label: "EN" }, { code: "ru", label: "RU" }].map(l => (
              <button key={l.code} onClick={() => { setLang(l.code, !!user); }}
                style={{
                  padding: "5px 12px", fontSize: 11, fontWeight: 700, letterSpacing: 1,
                  background: lang === l.code ? "#e53535" : "transparent",
                  color: lang === l.code ? "#fff" : "#555",
                  border: `1px solid ${lang === l.code ? "#e53535" : "#2a2a2a"}`,
                  cursor: "pointer", transition: "all 0.2s", borderRadius: 1,
                  fontFamily: "'Share Tech Mono', monospace"
                }}>
                {l.label}
              </button>
            ))}
          </div>
        </div>
        <button
          onClick={() => setMenuOpen(false)}
          style={{
            width: 32, height: 32, padding: 0, border: "1px solid #2a2a2a", borderRadius: 1,
            background: "transparent", cursor: "pointer",
            display: "flex", alignItems: "center", justifyContent: "center",
            color: "#e53535", transition: "all 0.2s"
          }}
          onMouseEnter={e => { e.currentTarget.style.borderColor = "#e53535"; e.currentTarget.style.background = "rgba(229,53,53,0.1)"; }}
          onMouseLeave={e => { e.currentTarget.style.borderColor = "#2a2a2a"; e.currentTarget.style.background = "transparent"; }}
          aria-label="Close menu"
        >
          <ChevronUp size={18} />
        </button>
      </motion.div>

      {/* Corner accents */}
      <div style={{ position: "absolute", bottom: 0, left: 0, width: 16, height: 16, borderBottom: "1px solid #e53535", borderLeft: "1px solid #e53535" }} />
      <div style={{ position: "absolute", bottom: 0, right: 0, width: 16, height: 16, borderBottom: "1px solid #e53535", borderRight: "1px solid #e53535" }} />
    </div>
  );
}

export default function Layout({ children, currentPageName }) {
  const navigate = useNavigate();
  const { user, isLoadingAuth } = useAuth();
  const userChecked = !isLoadingAuth;
  const [loading, setLoading] = useState(() => {
    try { return !sessionStorage.getItem("spy_loader_shown"); } catch { return true; }
  });
  const [menuOpen, setMenuOpen] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [isOpen, setIsOpen] = useState(false);

  // MENU_H reactive to resize
  const [MENU_H, setMENU_H] = useState(() => typeof window !== "undefined" ? window.innerHeight * 0.50 : 400);
  useEffect(() => {
    const onResize = () => {
      setMENU_H(window.innerHeight * 0.50);
    };
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  // Motion values — DOM updates bypass React re-renders entirely
  const drawerH = useMotionValue(0);
  const progress = useTransform(drawerH, h => MENU_H > 0 ? Math.min(1, Math.max(0, h / MENU_H)) : 0);
  const navHeight = useTransform(drawerH, h => `calc(80px + env(safe-area-inset-top, 0px) + ${h}px)`);
  const backdropOpacity = useTransform(progress, p => p * 0.6);

  const BOTTOM_NAV_HIDDEN = ["Room", "Game", "LocalGame", "QRScan", "Login", "Register", "ForgotPassword", "ResetPassword", "Welcome"];
  const showBottomNav = !!user && !BOTTOM_NAV_HIDDEN.includes(currentPageName);

  // Track isOpen for backdrop rendering + cursor
  useMotionValueEvent(drawerH, "change", (h) => {
    setIsOpen(h > 0.5);
  });

  const dragStartY = useRef(null);
  const dragStartH = useRef(0);
  const dragMoved = useRef(false);
  const currentAnim = useRef(null);

  useEffect(() => {
    const getCtx = () => {
      if (!window._audioCtx) {
        window._audioCtx = new (window.AudioContext || window.webkitAudioContext)();
      }
      return window._audioCtx;
    };

    const playSound = (type) => {
      try {
        const ctx = getCtx();
        if (ctx.state === "suspended") ctx.resume();

        if (type === "primary") {
          const notes = [523, 659, 784];
          notes.forEach((freq, i) => {
            const o = ctx.createOscillator();
            const g = ctx.createGain();
            o.connect(g); g.connect(ctx.destination);
            o.frequency.value = freq;
            o.type = "sine";
            const t = ctx.currentTime + i * 0.08;
            g.gain.setValueAtTime(0.18, t);
            g.gain.exponentialRampToValueAtTime(0.001, t + 0.12);
            o.start(t); o.stop(t + 0.12);
          });
        } else if (type === "secondary") {
          const notes = [440, 550, 660];
          notes.forEach((freq, i) => {
            const o = ctx.createOscillator();
            const g = ctx.createGain();
            o.connect(g); g.connect(ctx.destination);
            o.frequency.value = freq;
            o.type = "sine";
            const t = ctx.currentTime + i * 0.05;
            g.gain.setValueAtTime(0.14, t);
            g.gain.exponentialRampToValueAtTime(0.001, t + 0.1);
            o.start(t); o.stop(t + 0.1);
          });
        } else if (type === "tertiary") {
          const o = ctx.createOscillator();
          const g = ctx.createGain();
          o.connect(g); g.connect(ctx.destination);
          o.frequency.setValueAtTime(800, ctx.currentTime);
          g.gain.setValueAtTime(0.12, ctx.currentTime);
          g.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.06);
          o.start(); o.stop(ctx.currentTime + 0.06);
        }
      } catch {}
    };

    const handleClick = (e) => {
      const button = e.target.closest("button");
      if (!button) return;
      if (button.classList.contains("btn-red")) playSound("primary");
      else if (button.classList.contains("btn-outline")) playSound("secondary");
      else if (button.classList.contains("btn-ghost")) playSound("tertiary");
    };

    document.addEventListener("click", handleClick);
    return () => document.removeEventListener("click", handleClick);
  }, []);

  // Stop any running animation
  const stopAnim = useCallback(() => {
    if (currentAnim.current) {
      currentAnim.current.stop();
      currentAnim.current = null;
    }
  }, []);

  // Smooth animate drawer to target value
  const animateTo = useCallback((target, duration = 0.4) => {
    stopAnim();
    currentAnim.current = animate(drawerH, target, {
      duration,
      ease: [0.22, 0.61, 0.36, 1],
    });
  }, [drawerH, stopAnim]);

  // Drag handlers
  const onDragStart = useCallback((clientY) => {
    stopAnim();
    dragStartY.current = clientY;
    dragStartH.current = drawerH.get();
    dragMoved.current = false;
    setDragging(true);
  }, [drawerH, stopAnim]);

  const onDragMove = useCallback((clientY) => {
    if (dragStartY.current === null) return;
    const delta = clientY - dragStartY.current;
    if (Math.abs(delta) > 5) dragMoved.current = true;
    const newH = Math.max(0, Math.min(MENU_H, dragStartH.current + delta));
    drawerH.set(newH); // прямое обновление DOM, без re-render
  }, [MENU_H, drawerH]);

  const onDragEnd = useCallback((wasTap) => {
    if (dragStartY.current === null) return;
    dragStartY.current = null;
    setDragging(false);
    if (wasTap) return;
    const current = drawerH.get();
    if (current > MENU_H * 0.3) {
      animateTo(MENU_H, 0.3);
      setMenuOpen(true);
    } else {
      animateTo(0, 0.3);
      setMenuOpen(false);
    }
  }, [drawerH, MENU_H, animateTo]);

  // Sync menuOpen (от click toggle) → drawerH через animate
  useEffect(() => {
    if (dragging) return;
    animateTo(menuOpen ? MENU_H : 0, 0.45);
    return () => stopAnim();
  }, [menuOpen, MENU_H, dragging, animateTo, stopAnim]);

  // Touch / Mouse
  const handleTouchStart = (e) => { if (user) onDragStart(e.touches[0].clientY); };
  const handleTouchMove = (e) => { onDragMove(e.touches[0].clientY); };
  const handleTouchEnd = () => onDragEnd(!dragMoved.current);
  const handleMouseDown = (e) => { if (user) { onDragStart(e.clientY); } };

  useEffect(() => {
    if (!dragging) return;
    const onMove = (e) => onDragMove(e.clientY);
    const onUp = () => onDragEnd(!dragMoved.current);
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
    return () => { window.removeEventListener("mousemove", onMove); window.removeEventListener("mouseup", onUp); };
  }, [dragging, onDragMove, onDragEnd]);

  useEffect(() => {
    if (dragging) {
      const prev = document.body.style.userSelect;
      const prevWebkit = document.body.style.webkitUserSelect;
      document.body.style.userSelect = "none";
      document.body.style.webkitUserSelect = "none";
      return () => {
        document.body.style.userSelect = prev;
        document.body.style.webkitUserSelect = prevWebkit;
      };
    }
  }, [dragging]);

  if (loading) {
    return (
      <LanguageProvider>
        <AppLoader onDone={() => {
          try { sessionStorage.setItem("spy_loader_shown", "1"); } catch {}
          setLoading(false);
        }} />
      </LanguageProvider>
    );
  }

  return (
    <LanguageProvider>
      <div className="min-h-screen bg-black text-white" style={{ fontFamily: "'Share Tech Mono', 'Courier New', monospace" }}>
        <style>{`
          @import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Rajdhani:wght@500;600;700&display=swap');

          :root {
            --red: #e53535;
            --red-dim: rgba(229,53,53,0.15);
            --dark: #0a0a0a;
            --card: #0f0f0f;
            --border: #1e1e1e;
            --muted: #555;
            --text: #ccc;
          }
          * { box-sizing: border-box; margin: 0; padding: 0; }
          body { background: #000; color: #fff; }

          .mono { font-family: 'Share Tech Mono', monospace; }
          .heading { font-family: 'Rajdhani', sans-serif; font-weight: 700; letter-spacing: 2px; }

          .btn-red {
            background: #e53535;
            color: #fff;
            border: none;
            border-radius: 2px;
            padding: 12px 28px;
            font-weight: 700;
            cursor: pointer;
            font-size: 13px;
            letter-spacing: 2px;
            font-family: 'Share Tech Mono', monospace;
            text-transform: uppercase;
            transition: all 0.2s;
            clip-path: polygon(0 0, calc(100% - 8px) 0, 100% 8px, 100% 100%, 8px 100%, 0 calc(100% - 8px));
            position: relative;
          }
          .btn-red:hover { background: #cc2020; transform: translateY(-1px); box-shadow: 0 0 20px rgba(229,53,53,0.4); }
          .btn-red:disabled { opacity: 0.4; cursor: not-allowed; transform: none; box-shadow: none; }

          .btn-outline {
            background: transparent;
            color: #e53535;
            border: 1px solid #e53535;
            border-radius: 2px;
            padding: 11px 28px;
            font-weight: 700;
            cursor: pointer;
            font-size: 13px;
            letter-spacing: 2px;
            font-family: 'Share Tech Mono', monospace;
            text-transform: uppercase;
            transition: all 0.2s;
            clip-path: polygon(0 0, calc(100% - 8px) 0, 100% 8px, 100% 100%, 8px 100%, 0 calc(100% - 8px));
          }
          .btn-outline:hover { background: rgba(229,53,53,0.1); box-shadow: 0 0 15px rgba(229,53,53,0.2); }
          .btn-outline:disabled { opacity: 0.4; cursor: not-allowed; }

          .btn-ghost {
            background: transparent;
            color: #666;
            border: 1px solid #222;
            border-radius: 2px;
            padding: 11px 28px;
            font-weight: 700;
            cursor: pointer;
            font-size: 13px;
            letter-spacing: 2px;
            font-family: 'Share Tech Mono', monospace;
            text-transform: uppercase;
            transition: all 0.2s;
          }
          .btn-ghost:hover { border-color: #444; color: #aaa; }

          .card {
            background: #0f0f0f;
            border: 1px solid #1e1e1e;
            border-radius: 2px;
            position: relative;
          }
          .card::before {
            content: '';
            position: absolute;
            top: 0; left: 0;
            width: 12px; height: 12px;
            border-top: 1px solid #e53535;
            border-left: 1px solid #e53535;
          }
          .card::after {
            content: '';
            position: absolute;
            bottom: 0; right: 0;
            width: 12px; height: 12px;
            border-bottom: 1px solid #e53535;
            border-right: 1px solid #e53535;
          }

          input, textarea, select {
            background: #0a0a0a !important;
            border: 1px solid #2a2a2a !important;
            color: #fff !important;
            border-radius: 2px;
            padding: 10px 14px;
            font-size: 16px;
            font-family: 'Share Tech Mono', monospace;
            letter-spacing: 1px;
            outline: none;
            width: 100%;
            transition: border-color 0.2s;
          }
          @media (min-width: 768px) {
            input, textarea, select { font-size: 13px; }
          }
          input:focus, textarea:focus {
            border-color: #e53535 !important;
            box-shadow: 0 0 0 1px rgba(229,53,53,0.2);
          }
          input::placeholder { color: #444 !important; }

          .label-tag {
            font-size: 11px;
            letter-spacing: 2px;
            color: #666;
            text-transform: uppercase;
            font-family: 'Share Tech Mono', monospace;
            margin-bottom: 6px;
            display: block;
          }

          ::-webkit-scrollbar { width: 4px; }
          ::-webkit-scrollbar-track { background: #0a0a0a; }
          ::-webkit-scrollbar-thumb { background: #e53535; border-radius: 0; }

          @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.2} }
        `}</style>

        <div style={{
          position: "fixed", inset: 0, zIndex: 0, pointerEvents: "none",
          background: "radial-gradient(ellipse at 20% 50%, rgba(229,53,53,0.04) 0%, transparent 60%), radial-gradient(ellipse at 80% 20%, rgba(100,100,150,0.03) 0%, transparent 50%)"
        }} />

        {/* BACKDROP — motion opacity, no React re-renders */}
        <motion.div
          onClick={() => setMenuOpen(false)}
          style={{
            position: "fixed", inset: 0, top: 0,
            background: "#000",
            opacity: backdropOpacity,
            zIndex: 98,
            pointerEvents: isOpen ? "auto" : "none",
            willChange: "opacity",
          }}
        />

        {/* HEADER + DRAWER — height as motion value (нет re-renders во время drag) */}
        <motion.nav
          onTouchStart={handleTouchStart}
          onTouchMove={handleTouchMove}
          onTouchEnd={handleTouchEnd}
          onMouseDown={handleMouseDown}
          style={{
            position: "sticky", top: 0, zIndex: 100,
            background: "rgba(0,0,0,0.97)", backdropFilter: "blur(10px)",
            borderBottom: `1px solid ${isOpen ? "#e53535" : "#1a1a1a"}`,
            transition: "border-color 0.3s",
            height: navHeight,
            overflow: "hidden",
            cursor: user ? (dragging ? "grabbing" : "grab") : "default",
            userSelect: "none",
            touchAction: "none",
            display: "flex",
            flexDirection: "column",
            willChange: "height",
            contain: "layout style paint",
            transform: "translateZ(0)",
          }}
        >
          {/* Топ-бар */}
          <div style={{
            height: "calc(80px + env(safe-area-inset-top, 0px))",
            minHeight: "calc(80px + env(safe-area-inset-top, 0px))",
            flexShrink: 0,
            padding: "env(safe-area-inset-top, 0px) 16px 0",
            display: "flex", alignItems: "center", justifyContent: "space-between",
            position: "relative",
          }}>
            <div style={{ position: "absolute", top: 8, left: 8, width: 16, height: 16, borderTop: "1px solid #333", borderLeft: "1px solid #333" }} />
            <div style={{ position: "absolute", top: 8, right: 8, width: 16, height: 16, borderTop: "1px solid #333", borderRight: "1px solid #333" }} />

            {/* Drag handle indicator */}
            {user && (
              <div style={{
                position: "absolute", bottom: 6, left: "50%", transform: "translateX(-50%)",
                display: "flex", flexDirection: "column", gap: 3, alignItems: "center"
              }}>
                <div style={{ width: 32, height: 2, background: isOpen ? "#e53535" : "#333", borderRadius: 1, transition: "background 0.2s" }} />
                <div style={{ width: 20, height: 2, background: isOpen ? "#e53535" : "#222", borderRadius: 1, transition: "background 0.2s" }} />
              </div>
            )}

            <a
              href={createPageUrl("Home")}
              style={{ textDecoration: "none", padding: "9px 8px 7px", display: "flex", alignItems: "center" }}
              onMouseDown={e => e.stopPropagation()}
              onClick={(e) => {
                e.preventDefault();
                localStorage.removeItem("spy_return_to_play_mode");
                localStorage.removeItem("spy_return_to_online");
                navigate(createPageUrl("Home"), { state: { resetHome: Date.now() }, replace: false });
              }}
            >
              <motion.div whileHover={{ scale: 1.03 }} style={{ display: "flex", flexDirection: "column", alignItems: "flex-start" }}>
                <span style={{ display: "flex", alignItems: "center", gap: 2, lineHeight: 1 }}>
                  <span style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 30, letterSpacing: 3, color: "#e53535" }}>SPY</span>
                  <span style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 30, letterSpacing: 3, color: "#fff" }}>CLASH</span>
                </span>
                <span style={{ marginTop: 4, color: "#444", fontSize: 8, letterSpacing: 3, fontFamily: "'Share Tech Mono', monospace" }}>
                  1.29v
                </span>
              </motion.div>
            </a>

            {!userChecked ? (
              <div style={{ width: 60, height: 40 }} />
            ) : user ? (
              <MenuToggleButton
                isOpen={isOpen}
                progress={progress}
                onMouseDown={e => e.stopPropagation()}
                onClick={() => setMenuOpen(v => !v)}
              />
            ) : (
              <motion.button
                whileHover={{ scale: 1.02 }}
                whileTap={{ scale: 0.98 }}
                className="btn-red"
                style={{ padding: "10px 22px", fontSize: 13 }}
                onMouseDown={e => e.stopPropagation()}
                onClick={() => base44.auth.redirectToLogin(undefined)}
              >
                LOGIN
              </motion.button>
            )}
          </div>

          {/* Меню */}
          {user && (
            <div style={{ flex: 1, overflow: "hidden", position: "relative" }}>
              <LanguageContext.Consumer>
                {({ t: tCtx, lang: langCtx, setLang: setLangCtx }) => (
                  <MenuContent
                    user={user}
                    currentPageName={currentPageName}
                    setMenuOpen={setMenuOpen}
                    lang={langCtx}
                    setLang={setLangCtx}
                    t={tCtx}
                    progress={progress}
                  />
                )}
              </LanguageContext.Consumer>
            </div>
          )}
        </motion.nav>

        <main style={{
          position: "relative", zIndex: 1, minHeight: "calc(100vh - 140px)",
          userSelect: dragging ? "none" : "auto", WebkitUserSelect: dragging ? "none" : "auto",
          paddingBottom: showBottomNav ? "calc(100px + env(safe-area-inset-bottom, 0px))" : 0,
        }}>{children}</main>

        <footer style={{ borderTop: "1px solid #1a1a1a", padding: "20px 24px", display: currentPageName === "LocalGame" || user ? "none" : "flex", justifyContent: "center", gap: 24, position: "relative", zIndex: 1 }}>
          <Link to="/support" style={{ textDecoration: "none", fontSize: 10, letterSpacing: 2, color: "#444", textTransform: "uppercase", transition: "color 0.2s" }}
            onMouseEnter={e => e.currentTarget.style.color = "#e53535"} onMouseLeave={e => e.currentTarget.style.color = "#444"}>
            Support
          </Link>
          <Link to={createPageUrl("PrivacyPolicy")} style={{ textDecoration: "none", fontSize: 10, letterSpacing: 2, color: "#444", textTransform: "uppercase", transition: "color 0.2s" }}
            onMouseEnter={e => e.currentTarget.style.color = "#e53535"} onMouseLeave={e => e.currentTarget.style.color = "#444"}>
            Privacy Policy
          </Link>
          <Link to={createPageUrl("TermsOfService")} style={{ textDecoration: "none", fontSize: 10, letterSpacing: 2, color: "#444", textTransform: "uppercase", transition: "color 0.2s" }}
            onMouseEnter={e => e.currentTarget.style.color = "#e53535"} onMouseLeave={e => e.currentTarget.style.color = "#444"}>
            Terms of Service
          </Link>
        </footer>

        <PWAInstallPrompt />
      </div>
    </LanguageProvider>
  );
}
