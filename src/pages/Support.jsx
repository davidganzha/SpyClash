import { motion } from "framer-motion";
import { Link, useNavigate } from "react-router-dom";
import Reveal from "@/components/Reveal";
import { createPageUrl } from "@/utils";

const DEFAULT_SUPPORT_EMAIL = "yanushevych.mr@gmail.com";
const supportEmail = String(
  document.querySelector('meta[name="spyclash-support-email"]')?.getAttribute("content")
  || DEFAULT_SUPPORT_EMAIL
).trim();

const supportTopics = [
  {
    title: "ROOM OR QR PROBLEMS",
    text: "Confirm that every player is using the current SpyClash version. The host can share the six-character room code when camera access or QR scanning is unavailable."
  },
  {
    title: "DELETE YOUR ACCOUNT",
    text: "In the iOS app, open Profile, scroll to DANGER ZONE, and choose DELETE ACCOUNT. Profile data, saved word packs, and match history are removed; limited transaction records may be retained for legal, accounting, and fraud-prevention obligations."
  },
  {
    title: "REPORT OR BLOCK COMMUNITY ABUSE",
    text: "Open the operative's Community profile to report the account or block it. Individual profile-wall comments also have a Report control. Reports are private and placed in an administrator-only moderation queue. Blocking prevents both accounts from finding or contacting each other in Community and removes their existing comments and room invitations. Include your Spy ID and the approximate time of the incident if you contact support for a review or appeal."
  }
];

export default function Support() {
  const navigate = useNavigate();
  const subject = encodeURIComponent("SpyClash support request");

  return (
    <div style={{ minHeight: "100vh", padding: "60px 20px", background: "#000" }}>
      <div style={{ maxWidth: 760, margin: "0 auto" }}>
        <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }}>
          <div style={{ fontSize: 10, letterSpacing: 4, color: "#555", marginBottom: 12, textTransform: "uppercase" }}>Support</div>
          <h1 style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 36, letterSpacing: 3, marginBottom: 8, color: "#fff" }}>
            SPYCLASH SUPPORT
          </h1>
          <p style={{ color: "#777", fontSize: 13, lineHeight: 1.8, marginBottom: 36 }}>
            Include your Spy ID, device model, iOS version, and a short description of the problem. Never send passwords, payment-card details, or Apple verification codes.
          </p>

          <div style={{ display: "flex", flexDirection: "column", gap: 30 }}>
            {supportTopics.map((topic, index) => (
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
              CONTACT
            </div>
            <a className="btn-primary" href={`mailto:${supportEmail}?subject=${subject}`} style={{ display: "inline-flex", textDecoration: "none" }}>
              EMAIL {supportEmail.toUpperCase()}
            </a>
          </div>

          <div style={{ display: "flex", flexWrap: "wrap", gap: 16, marginTop: 28, fontSize: 11, letterSpacing: 1.4 }}>
            <Link to="/privacypolicy" style={{ color: "#aaa" }}>PRIVACY POLICY</Link>
            <Link to="/termsofservice" style={{ color: "#aaa" }}>TERMS</Link>
          </div>

          <div style={{ marginTop: 52, paddingTop: 24, borderTop: "1px solid #1a1a1a" }}>
            <button className="btn-ghost" style={{ fontSize: 11 }} onClick={() => navigate(createPageUrl("Home"))}>
              ← BACK TO HOME
            </button>
          </div>
        </motion.div>
      </div>
    </div>
  );
}
