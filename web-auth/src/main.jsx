import { isMobileAuthCallbackRoute, mountMobileAuthCallback } from './lib/mobileAuthCallback.js';
import { isMobileAppleAuthCallbackRoute, mountMobileAppleAuthCallback } from './lib/mobileAppleAuthCallback.js';

// Never load App, the SDK or browser session storage for a native OAuth return.
if (isMobileAuthCallbackRoute(window.location)) {
  mountMobileAuthCallback(document, window);
} else if (isMobileAppleAuthCallbackRoute(window.location)) {
  mountMobileAppleAuthCallback(document, window);
} else {
  import('./bootstrap.jsx');
}
