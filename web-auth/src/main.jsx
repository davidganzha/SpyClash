import { isMobileAuthCallbackRoute, mountMobileAuthCallback } from './lib/mobileAuthCallback.js';

// Never load App, the SDK or browser session storage for a native OAuth return.
if (isMobileAuthCallbackRoute(window.location)) {
  mountMobileAuthCallback(document, window);
} else {
  import('./bootstrap.jsx');
}
