import { QRCodeSVG } from "qrcode.react";
import { motion } from "framer-motion";
import { useState } from "react";
import { useLanguage } from "@/components/LanguageContext";

export default function QRInvite({ roomId, roomCode, embedded = false }) {
  const { t } = useLanguage();
  const [copied, setCopied] = useState(false);

  const joinUrl = `${window.location.origin}/#/Home?join=${roomCode}`;

  const handleCopy = () => {
    navigator.clipboard.writeText(joinUrl);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <motion.div initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }}
    style={{
      position: "relative",
      background: embedded ? "transparent" : "#0a0a0a",
      border: embedded ? "none" : "1px solid #1e1e1e",
      padding: embedded ? "8px 12px 22px" : 24,
      marginBottom: embedded ? 0 : 16,
      textAlign: "center",
    }}>
      <div style={{ position: "absolute", top: 0, left: 0, width: 12, height: 12, borderTop: "1px solid #fff", borderLeft: "1px solid #fff" }} />
      <div style={{ position: "absolute", top: 0, right: 0, width: 12, height: 12, borderTop: "1px solid #fff", borderRight: "1px solid #fff" }} />
      <div style={{ position: "absolute", bottom: 0, left: 0, width: 12, height: 12, borderBottom: "1px solid #fff", borderLeft: "1px solid #fff" }} />
      <div style={{ position: "absolute", bottom: 0, right: 0, width: 12, height: 12, borderBottom: "1px solid #fff", borderRight: "1px solid #fff" }} />

      <div style={{ fontSize: 10, letterSpacing: 3, color: "#555", marginBottom: embedded ? 10 : 16 }}>// {t('qr_invitation')}</div>

      {/* Styled QR wrapper */}
      <div style={{ position: "relative", display: "inline-block" }}>
        {/* Animated corner scanlines */}
        <motion.div animate={{ opacity: [0.2, 0.8, 0.2], boxShadow: ["0 0 8px rgba(255,255,255,0.1)", "0 0 24px rgba(255,255,255,0.35)", "0 0 8px rgba(255,255,255,0.1)"] }} transition={{ duration: 2, repeat: Infinity }}
        style={{ position: "absolute", inset: -8, border: "1px solid rgba(255,255,255,0.3)", pointerEvents: "none", zIndex: 2 }} />

        {/* QR Code — white bg for scannability */}
        <div style={{
          padding: 12,
          background: "#ffffff",
          borderRadius: 4,
          boxShadow: "0 0 0 1px rgba(139,0,0,0.5), 0 0 28px rgba(139,0,0,0.2)",
          position: "relative"
        }}>
          <QRCodeSVG
            value={joinUrl}
            size={embedded ? 132 : 180}
            bgColor="#ffffff"
            fgColor="#000000"
            level="H"
            includeMargin={false} />
          
          {/* Center logo overlay */}
          <div style={{
            position: "absolute",
            top: "50%", left: "50%",
            transform: "translate(-50%, -50%)",
            background: "#ffffff",
            borderRadius: "50%",
            padding: 3,
            pointerEvents: "none"
          }}>
            <img src="https://media.base44.com/images/public/69a0e57fa939f578082f8091/24fa4fecb_.png" width={36} height={36} style={{ display: "block", borderRadius: "50%" }} alt="logo" />
          </div>
        </div>
      </div>



      {/* Copy link */}
      <div style={{ marginTop: 16 }}>
      











        
      </div>
    </motion.div>);

}
