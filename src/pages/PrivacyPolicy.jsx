import { motion } from "framer-motion";
import { useNavigate } from "react-router-dom";
import { createPageUrl } from "@/utils";
import Reveal from "@/components/Reveal";

export default function PrivacyPolicy() {
  const navigate = useNavigate();

  return (
    <div style={{ minHeight: "calc(100vh - 80px)", padding: "60px 20px" }}>
      <div style={{ maxWidth: 760, margin: "0 auto" }}>
        <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }}>
          <div style={{ fontSize: 10, letterSpacing: 4, color: "#555", marginBottom: 12, textTransform: "uppercase" }}>Legal</div>
          <h1 style={{ fontFamily: "'Rajdhani', sans-serif", fontWeight: 700, fontSize: 36, letterSpacing: 3, marginBottom: 8, color: "#fff" }}>
            PRIVACY POLICY
          </h1>
          <div style={{ color: "#444", fontSize: 11, letterSpacing: 2, marginBottom: 48 }}>Last updated: July 2026</div>

          <div style={{ display: "flex", flexDirection: "column", gap: 36 }}>
            {[
              {
                title: "1. INFORMATION WE COLLECT",
                text: "SpyClash is operated by David Ganzha, an individual developer and the data controller for this service. We collect information you provide directly, including your email address, display name, avatar, profile comments, and custom word packs. We store friend requests, accepted friendships, and blocked-player relationships that form your in-service social graph. Accepted friends may be visible on player profiles. SpyClash does not access or upload your device address book. When you submit a Community report, we store the selected reason, the reporter and reported account identifiers, and a private snapshot of the reported comment when applicable. We store account identifiers, private room and game state, match history, scores, and gameplay statistics. We process AI-generation requests and retain generated results and limited account-linked metadata. Our own cache does not retain the raw theme or exclusion words; it stores request or replay identifiers, one-way theme and exclusion keys, language keys, requested and returned counts, cache outcomes, and provider-attempt results. Some of these account-linked fields are used to evaluate generator reliability. They are not used for advertising or cross-company tracking. To deliver notifications and Live Activities, we collect a randomly generated installation identifier, APNs and ActivityKit push tokens, notification authorization status and preferences, app version, and selected language or locale. We also retain delivery states, attempt counts, and error codes needed to retry delivery, revoke invalid tokens, and diagnose notification failures. The Base44 backend stores one-way installation and token hashes and encrypts raw push tokens. These registrations are linked to your signed-in account only to deliver requested game, friend, room, and match updates and are not used for advertising or tracking. If your account has a transaction from a retired billing program, we may retain limited provider transaction identifiers, status, and dates for support, disputes, accounting, fraud prevention, and legal compliance; we do not receive your full payment-card details. QR camera frames and ARKit Camera Assistance data used to stabilize local Nearby Interaction/Radar ranging are processed on device and are not uploaded or retained."
              },
              {
                title: "2. HOW WE USE YOUR INFORMATION",
                text: "We use the information we collect to operate and improve the game, measure the reliability of existing features, host and moderate user content, investigate Community reports, enforce the Community Standards, provide customer support, send game-related notifications, and display leaderboards and player statistics."
              },
              {
                title: "3. DATA SHARING",
                text: "We do not sell your personal information. Base44 provides authentication, application hosting, database storage, server functions, and operational infrastructure. When you request an AI word pack, the theme, requested count, exclusion words, and language are sent to the configured direct AI endpoint, which defaults to OpenAI's Responses API. On specified operational or configuration failures, the same input may also be processed through Base44 InvokeLLM; Base44 may process that fallback through its configured AI model provider. Provider-side processing and retention are governed by the applicable provider terms and configuration. Apple processes data for Sign in with Apple, App Store transaction support, APNs notification delivery, and ActivityKit Live Activities. To deliver a notification or Live Activity, the backend sends Apple the token and the corresponding alert or public match-state payload. These payloads may include display names, avatar symbols, participant status, round, public category, timer, and navigation identifiers, but not email, room join code, role, or secret word. Google is used only when you choose Google sign-in. Stripe is used only where needed to resolve records or disputes from a retired web-billing program. We limit disclosures to the service functions described here and configure and oversee our service providers to protect personal data consistently with this policy and applicable law. Your display name, avatar, accepted friends, profile comments, competitive statistics, and content you choose to share may be visible to other SpyClash players. A custom word pack may be shown to participants when you select it for a game. Community reports and their snapshots are not public and are available only to authorized administrators and necessary service providers."
              },
              {
                title: "4. DATA STORAGE",
                text: "Account data is retained while your account is active or for the operational periods described here. AI cache variants expire after seven days, and successful replay records expire after 24 hours; expired rows may remain until cleanup runs but are no longer used. You can delete the account in the iOS app under Profile > Danger Zone. Deletion removes profile data, custom word packs, friend requests, accepted friendships, blocks, profile comments, room invitations, active room references, match-history records, account-scoped AI usage, cache and replay records, push-device registrations, and Live Activity registrations. We attempt to revoke the stored Sign in with Apple refresh credential and scrub our stored copy. If Apple revocation cannot be confirmed, the app informs you that manual revocation may be required. For a Community report involving the deleted account, raw account identifiers are replaced with stable deletion tombstones. The private report and its content snapshot may be retained only as reasonably necessary for safety investigation, enforcement, and legal records; access remains limited to authorized administrators and necessary service providers. Limited legacy transaction records may be retained where needed for accounting, fraud prevention, dispute handling, and legal obligations. If you still have a provider-managed legacy billing agreement, account deletion does not cancel it; manage it directly with that provider."
              },
              {
                title: "5. PRODUCT METRICS AND WEBSITE STORAGE",
                text: "SpyClash retains the limited account-linked product-interaction records described above for app functionality and feature-reliability analytics. The website uses local storage for language and authentication session state. Automatic third-party and platform website-usage analytics are disabled in the release website; the native iOS app does not include advertising or cross-app tracking SDKs."
              },
              {
                title: "6. CHILDREN'S PRIVACY",
                text: "Our service is not directed to children under the age of 13. If we learn that we collected personal information from a child under 13 without valid authorization, we will take reasonable steps to delete it."
              },
              {
                title: "7. CHANGES TO THIS POLICY",
                text: "We may update this Privacy Policy from time to time. We will notify you of any changes by posting the new policy on this page with an updated date."
              },
              {
                title: "8. CONTACT US",
                text: "SpyClash is operated by David Ganzha. For privacy questions, access or deletion requests, or other data-rights assistance, use the current contact method published at https://spyclash.com/support."
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
