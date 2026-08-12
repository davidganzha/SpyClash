import { NavLink, useLocation } from "react-router-dom";
import { createPageUrl } from "@/utils";
import {
  ArrowLeft,
  Contact,
  Home as HomeIcon,
  Package,
  User as UserIcon,
} from "lucide-react";
import { motion } from "framer-motion";
import { useLanguage } from "@/components/LanguageContext";
import { localize } from "@/components/i18n";
import { useAuth } from "@/lib/AuthContext";
import { useCommunity } from "@/lib/CommunityContext";

const HIDDEN_PATHS = [
  "/room",
  "/game",
  "/localgame",
  "/qrscan",
  "/login",
  "/register",
  "/forgot-password",
  "/reset-password",
  "/welcome",
];

export default function BottomNav() {
  const { lang } = useLanguage();
  const { isAuthenticated } = useAuth();
  const { attentionCount } = useCommunity();
  const location = useLocation();

  const currentPath = location.pathname.toLowerCase();
  const isHidden = HIDDEN_PATHS.some(
    (path) => currentPath === path || currentPath.startsWith(`${path}/`),
  );

  if (!isAuthenticated || isHidden) return null;

  const isCommunity = currentPath === "/community";
  const normalItems = [
    {
      to: createPageUrl("Home"),
      icon: HomeIcon,
      label: localize(lang, "HOME", "ДОМОЙ", "ГОЛОВНА"),
      active: ["/", "/home"].includes(currentPath),
    },
    {
      to: createPageUrl("WordPacks"),
      icon: Package,
      label: localize(lang, "PACKS", "КОЛОДЫ", "НАБОРИ"),
      active: currentPath === "/wordpacks",
    },
    {
      to: createPageUrl("Profile"),
      icon: UserIcon,
      label: localize(lang, "PROFILE", "ПРОФИЛЬ", "ПРОФІЛЬ"),
      active: currentPath === "/profile",
    },
  ];
  const communityItems = [
    {
      to: createPageUrl("Home"),
      icon: ArrowLeft,
      label: localize(lang, "RETURN", "НАЗАД", "НАЗАД"),
      active: false,
    },
    {
      to: createPageUrl("Community"),
      icon: Contact,
      label: localize(lang, "COMMUNITY", "СЕТЬ", "СПІЛЬНОТА"),
      active: true,
      badge: attentionCount,
    },
    {
      to: createPageUrl("Profile"),
      icon: UserIcon,
      label: localize(lang, "MY PROFILE", "МОЙ ПРОФИЛЬ", "МІЙ ПРОФІЛЬ"),
      active: false,
    },
  ];
  const items = isCommunity ? communityItems : normalItems;

  return (
    <motion.div
      initial={{ y: 60, opacity: 0, scale: 0.94 }}
      animate={{ y: 0, opacity: 1, scale: 1 }}
      transition={{ duration: 0.42, ease: [0.22, 1, 0.36, 1] }}
      style={{
        position: "fixed",
        left: 0,
        right: 0,
        bottom: "calc(env(safe-area-inset-bottom, 0px) + 8px)",
        zIndex: 99,
        display: "flex",
        justifyContent: "center",
        padding: "0 10px",
        pointerEvents: "none",
      }}
    >
      <nav
        aria-label={localize(lang, "Primary navigation", "Основная навигация", "Основна навігація")}
        style={{
          pointerEvents: "auto",
          position: "relative",
          display: "flex",
          alignItems: "stretch",
          padding: "0 8px",
          width: "100%",
          maxWidth: 348,
          height: 62,
          overflow: "hidden",
          borderRadius: 15,
          background: "rgba(0,0,0,0.72)",
          border: "1px solid rgba(255,255,255,0.035)",
          backdropFilter: "blur(24px) saturate(145%)",
          WebkitBackdropFilter: "blur(24px) saturate(145%)",
          boxShadow: "0 9px 26px rgba(0,0,0,0.34)",
        }}
      >
        {items.map(({ to, icon: Icon, label, active, badge = 0 }) => (
          <NavLink
            key={`${to}-${label}`}
            to={to}
            aria-label={label}
            aria-current={active ? "page" : undefined}
            style={{ flex: 1, minWidth: 0, textDecoration: "none" }}
          >
            <motion.div
              whileTap={{ scale: 0.9 }}
              transition={{ type: "spring", stiffness: 420, damping: 26 }}
              style={{
                position: "relative",
                display: "grid",
                placeItems: "center",
                height: 58,
                color: active ? "#e53535" : "rgba(255,255,255,0.44)",
              }}
            >
              <motion.div
                animate={{ scale: active ? 1.12 : 1, y: active ? -1 : 0 }}
                transition={{ type: "spring", stiffness: 420, damping: 26 }}
                style={{ position: "relative", lineHeight: 0 }}
              >
                <Icon size={25} strokeWidth={active ? 2.8 : 2.1} />
                {badge > 0 && (
                  <span
                    style={{
                      position: "absolute",
                      top: -8,
                      right: -13,
                      minWidth: 17,
                      height: 17,
                      padding: "0 4px",
                      borderRadius: 9,
                      display: "grid",
                      placeItems: "center",
                      background: "#e53535",
                      color: "#fff",
                      fontSize: 8,
                      fontWeight: 800,
                      lineHeight: 1,
                    }}
                  >
                    {badge > 99 ? "99+" : badge}
                  </span>
                )}
              </motion.div>

              {active && (
                <motion.span
                  layoutId="dock-active-redline"
                  style={{
                    position: "absolute",
                    bottom: 2,
                    width: 28,
                    height: 2,
                    background: "#e53535",
                  }}
                />
              )}
            </motion.div>
          </NavLink>
        ))}
      </nav>
    </motion.div>
  );
}
