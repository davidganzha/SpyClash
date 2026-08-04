import { Navigate } from "react-router-dom";

// Kept as a compatibility landing point for old bookmarks and provider links.
// The app has no pricing surface, so every visit returns safely to the app.
export default function Pricing() {
  return <Navigate to="/" replace />;
}
