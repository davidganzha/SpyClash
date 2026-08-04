interface ImportMetaEnv {
  readonly PROD: boolean;
  readonly VITE_BASE44_APP_ID?: string;
  readonly VITE_BASE44_FUNCTIONS_VERSION?: string;
  readonly VITE_BASE44_APP_BASE_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

interface BarcodeDetectorResult {
  readonly rawValue: string;
}

interface BarcodeDetectorInstance {
  detect(source: HTMLCanvasElement): Promise<BarcodeDetectorResult[]>;
}

interface BarcodeDetectorConstructor {
  new (options?: { formats?: string[] }): BarcodeDetectorInstance;
}

interface Window {
  _audioCtx?: AudioContext;
  webkitAudioContext?: typeof AudioContext;
  dataLayer?: unknown[];
  gtag?: (...args: unknown[]) => void;
  BarcodeDetector?: BarcodeDetectorConstructor;
}
