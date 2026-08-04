import { motion } from "framer-motion";
import { useNavigate } from "react-router-dom";
import { createPageUrl } from "@/utils";
import Reveal from "@/components/Reveal";

export default function TermsOfService() {
  const navigate = useNavigate();

  return (
    <div style={{ minHeight: "calc(100vh - 80px)", padding: "60px 20px" }}>
      <div style={{ maxWidth: 760, margin: "0 auto" }}>
        <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }}>
          <div style={{ fontSize: 10, letterSpacing: 4, color: "#555", marginBottom: 12, textTransform: "uppercase" }}>Legal</div>
          <h1 style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 36, letterSpacing: 3, marginBottom: 8, color: "#fff" }}>
            TERMS OF SERVICE
          </h1>
          <div style={{ color: "#444", fontSize: 11, letterSpacing: 2, marginBottom: 48 }}>Last updated: July 2026</div>

          <div style={{ display: "flex", flexDirection: "column", gap: 36 }}>
            {[
              {
                title: "1. ACCEPTANCE OF TERMS",
                text: "SpyClash is operated by David Ganzha. By accessing or using SpyClash, you agree to be bound by these Terms of Service. If you do not agree to these terms, please do not use our service."
              },
              {
                title: "2. USE OF THE SERVICE",
                text: "SpyClash is a multiplayer social deduction game intended for entertainment purposes. You must be at least 13 years old to use this service. You agree to use the service only for lawful purposes and in a manner that does not infringe the rights of others."
              },
              {
                title: "3. ACCOUNT RESPONSIBILITY",
                text: "You are responsible for maintaining the confidentiality of your account credentials and for all activities that occur under your account. You agree to notify us immediately of any unauthorized use of your account."
              },
              {
                title: "4. FAIR PLAY",
                text: "You agree to play fairly and not to use any cheats, exploits, automation software, bots, hacks, or any unauthorized third-party software that may affect the gameplay. Violations may result in account suspension or termination."
              },
              {
                title: "5. CONTENT",
                text: "You agree not to use the game to transmit any content that is unlawful, harmful, threatening, abusive, harassing, defamatory, or otherwise objectionable. We reserve the right to remove any content that violates these terms."
              },
              {
                title: "6. USER CONTENT AND LICENSE",
                text: "You retain ownership of content you create or submit, including display names, avatars, comments, and custom word packs. You represent and warrant that you own that content or have every right needed to submit it and that it does not infringe any third party's rights. By submitting user content, you grant SpyClash a worldwide, non-exclusive, royalty-free, sublicensable, and transferable license to host, store, reproduce, format, adapt for technical requirements, publicly display, communicate, distribute, moderate, and otherwise use that content as necessary to operate, provide, secure, improve, and promote the service. This license lasts only as long as reasonably necessary for those purposes, subject to content already shared with other users, backups, legal retention, and enforcement records. You may delete content where controls are provided, and we may remove content that violates these Terms."
              },
              {
                title: "7. COMMUNITY STANDARDS AND SAFETY",
                text: "Do not post harassment, bullying, hate speech, threats, encouragement of self-harm, sexual or exploitative content, illegal content, spam, impersonation, private information, or other abusive material. Automated server filters may reject objectionable submissions, but no filter is perfect. Use Report on a profile or comment to send a private report for moderation review. Use Block to stop both accounts from discovering or opening each other's profiles, commenting, or sending room invitations; existing comments and invitations between the accounts are removed. We may remove content, restrict features, suspend, or terminate accounts after review. Knowingly false or abusive reports also violate these Standards. For a review or appeal request, visit https://spyclash.com/support."
              },
              {
                title: "8. INTELLECTUAL PROPERTY",
                text: "Except for user content, the SpyClash software, brand, original artwork, features, and functionality are owned by us or used under license and are protected by international copyright, trademark, and other intellectual property laws."
              },
              {
                title: "9. DISCLAIMER OF WARRANTIES",
                text: "SpyClash is provided 'as is' without any warranties of any kind, either express or implied. We do not warrant that the service will be uninterrupted, error-free, or free of viruses or other harmful components."
              },
              {
                title: "10. LIMITATION OF LIABILITY",
                text: "To the maximum extent permitted by law, we shall not be liable for any indirect, incidental, special, consequential, or punitive damages arising out of or related to your use of the service."
              },
              {
                title: "11. CHANGES TO TERMS",
                text: "We reserve the right to modify these Terms of Service at any time. We will notify users of significant changes by posting an updated version on this page. Continued use of the service after changes constitutes acceptance of the new terms."
              },
              {
                title: "12. CONTACT",
                text: "For support or questions about these Terms, visit https://spyclash.com/support."
              }
            ].map((section, i) => (
              <Reveal key={i} delay={i * 30}>
                <div style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 14, letterSpacing: 3, color: "#e53535", marginBottom: 10 }}>
                  {section.title}
                </div>
                <div style={{ color: "#888", fontSize: 13, lineHeight: 1.9, letterSpacing: 0.5 }}>{section.text}</div>
              </Reveal>
            ))}
          </div>

          <div style={{ marginTop: 60, paddingTop: 24, borderTop: "1px solid #1a1a1a" }}>
            <button className="btn-ghost" style={{ fontSize: 11 }} onClick={() => navigate(createPageUrl("Home"))}>
              ← BACK TO HOME
            </button>
          </div>
        </motion.div>
      </div>
    </div>
  );
}
