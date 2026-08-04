import { motion } from "framer-motion";

// Wraps each route element so it animates in/out on navigation.
// Pure fade — no Y shift, no scale — so nothing twitches.
export default function PageTransition({ children }) {
  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={{ duration: 0.22, ease: "easeInOut" }}
      style={{ minHeight: "100%", width: "100%" }}
    >
      {children}
    </motion.div>
  );
}