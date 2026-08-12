import { Toaster } from "@/components/ui/toaster"
import { QueryClientProvider } from '@tanstack/react-query'
import { queryClientInstance } from '@/lib/query-client'
import { pagesConfig } from './pages.config'
import { BrowserRouter as Router, Route, Routes, Navigate, useLocation } from 'react-router-dom';
import { AnimatePresence } from 'framer-motion';
import Home from './pages/Home';
import PageNotFound from './lib/PageNotFound';
import { AuthProvider, useAuth } from '@/lib/AuthContext';
import { MembershipProvider } from '@/lib/MembershipContext';
import { CommunityProvider } from '@/lib/CommunityContext';
import ErrorBoundary from '@/components/ErrorBoundary';
import ScrollToTop from '@/components/ScrollToTop';
import ProtectedRoute from '@/components/ProtectedRoute';
import PageTransition from '@/components/PageTransition';
import BottomNav from '@/components/BottomNav';
import QRScan from './pages/QRScan';
import LocalGame from './pages/LocalGame';
import Login from './pages/Login';
import Register from './pages/Register';
import ForgotPassword from './pages/ForgotPassword';
import ResetPassword from './pages/ResetPassword';
import Welcome from './pages/Welcome';
import PrivacyPolicy from './pages/PrivacyPolicy';
import Support from './pages/Support';
import TermsOfService from './pages/TermsOfService';
import WebReleaseNotice from '@/components/WebReleaseNotice';
import { LanguageProvider, useLanguage } from '@/components/LanguageContext';
import { localize } from '@/components/i18n';

const { Pages, Layout } = pagesConfig;
const PUBLIC_PAGE_NAMES = new Set(['PrivacyPolicy', 'Support', 'TermsOfService']);

const LayoutWrapper = ({ children, currentPageName }) => Layout ?
  <Layout currentPageName={currentPageName}>{children}</Layout>
  : <>{children}</>;

const AuthFallback = (
  <div className="fixed inset-0 flex items-center justify-center" style={{ background: "#000" }}>
    <div className="w-8 h-8 border-4 border-red-900 border-t-red-500 rounded-full animate-spin"></div>
  </div>
);

const WelcomeRoute = () => {
  const { isAuthenticated, isLoadingAuth } = useAuth();
  if (isLoadingAuth) return AuthFallback;
  if (isAuthenticated) return <Navigate to="/" replace />;
  return <Welcome />;
};

const AppShell = () => {
  const { isLoadingPublicSettings, authError } = useAuth();
  const { lang } = useLanguage();
  const location = useLocation();
  const publicInformationRoute = ['/privacypolicy', '/support', '/termsofservice']
    .includes(location.pathname.toLowerCase());

  // Legal and support pages must stay available even when the application API
  // is degraded; App Store review and account-deletion help depend on them.
  if (!publicInformationRoute && isLoadingPublicSettings) {
    return AuthFallback;
  }

  // Only unknown app-level errors block the whole app — auth_required and
  // user_not_registered are handled by ProtectedRoute on gated routes.
  if (!publicInformationRoute && authError && authError.type !== 'auth_required' && authError.type !== 'user_not_registered') {
    return (
      <div className="fixed inset-0 flex flex-col items-center justify-center" style={{ background: "#000" }}>
        <div style={{ color: "#e53535", fontSize: 28, marginBottom: 16 }}>⚠</div>
        <div style={{ color: "#888", fontSize: 12, letterSpacing: 3, fontFamily: "monospace", marginBottom: 8 }}>
          {localize(lang, "CONNECTION ERROR", "ОШИБКА СОЕДИНЕНИЯ", "ПОМИЛКА З'ЄДНАННЯ")}
        </div>
        <div style={{ color: "#444", fontSize: 11, letterSpacing: 1, fontFamily: "monospace", marginBottom: 24 }}>{authError.message}</div>
        <button
          onClick={() => window.location.reload()}
          style={{ background: "#e53535", color: "#fff", border: "none", padding: "10px 28px", fontSize: 12, letterSpacing: 3, fontFamily: "monospace", cursor: "pointer" }}
        >{localize(lang, "RETRY", "ПОВТОРИТЬ", "ПОВТОРИТИ")}</button>
      </div>
    );
  }

  return (
    <>
      <WebReleaseNotice />
      <AnimatedRoutes />
      <BottomNav />
    </>
  );
};

const AnimatedRoutes = () => {
  const location = useLocation();
  return (
    <AnimatePresence mode="wait">
      <Routes location={location} key={location.pathname}>
        {/* Public auth routes */}
        <Route path="/welcome" element={<PageTransition><WelcomeRoute /></PageTransition>} />
        <Route path="/login" element={<PageTransition><Login /></PageTransition>} />
        <Route path="/register" element={<PageTransition><Register /></PageTransition>} />
        <Route path="/forgot-password" element={<PageTransition><ForgotPassword /></PageTransition>} />
        <Route path="/reset-password" element={<PageTransition><ResetPassword /></PageTransition>} />
        <Route path="/privacypolicy" element={<PageTransition><PrivacyPolicy /></PageTransition>} />
        <Route path="/support" element={<PageTransition><Support /></PageTransition>} />
        <Route path="/termsofservice" element={<PageTransition><TermsOfService /></PageTransition>} />

        {/* Everything else is gated — unauth sees Welcome inline on the same URL */}
        <Route element={<ProtectedRoute fallback={AuthFallback} unauthenticatedElement={<Welcome />} />}>
          <Route path="/" element={<LayoutWrapper currentPageName="Home"><PageTransition><Home /></PageTransition></LayoutWrapper>} />
          <Route path="/home" element={<LayoutWrapper currentPageName="Home"><PageTransition><Home /></PageTransition></LayoutWrapper>} />
          {Object.entries(Pages).filter(([path]) => !PUBLIC_PAGE_NAMES.has(path)).map(([path, Page]) => (
            <Route
              key={path}
              path={`/${path}`}
              element={
                <LayoutWrapper currentPageName={path}>
                  <PageTransition><Page /></PageTransition>
                </LayoutWrapper>
              }
            />
          ))}
          <Route path="/QRScan" element={
            <LayoutWrapper currentPageName="QRScan">
              <PageTransition><QRScan /></PageTransition>
            </LayoutWrapper>
          } />
          <Route path="/LocalGame" element={
            <LayoutWrapper currentPageName="LocalGame">
              <PageTransition><LocalGame /></PageTransition>
            </LayoutWrapper>
          } />
          <Route path="/Pricing" element={<Navigate to="/" replace />} />
        </Route>

        <Route path="*" element={<PageTransition><PageNotFound /></PageTransition>} />
      </Routes>
    </AnimatePresence>
  );
};


function App() {

  return (
    <ErrorBoundary>
      <AuthProvider>
        <LanguageProvider>
          <CommunityProvider>
            <MembershipProvider>
              <QueryClientProvider client={queryClientInstance}>
                <Router>
                  <ScrollToTop />
                  <AppShell />
                </Router>
                <Toaster />
              </QueryClientProvider>
            </MembershipProvider>
          </CommunityProvider>
        </LanguageProvider>
      </AuthProvider>
    </ErrorBoundary>
  )
}

export default App
