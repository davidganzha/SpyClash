import jsQR from "jsqr";

export const QR_CAMERA_FRAME_SIZE = 512;

export function drawVideoCenterCrop(video, canvas, size = QR_CAMERA_FRAME_SIZE) {
  const sourceWidth = video.videoWidth;
  const sourceHeight = video.videoHeight;
  if (!sourceWidth || !sourceHeight) return null;

  const sourceSide = Math.min(sourceWidth, sourceHeight);
  const sourceX = Math.floor((sourceWidth - sourceSide) / 2);
  const sourceY = Math.floor((sourceHeight - sourceSide) / 2);

  if (canvas.width !== size || canvas.height !== size) {
    canvas.width = size;
    canvas.height = size;
  }

  const context = canvas.getContext("2d", { alpha: false, willReadFrequently: true });
  if (!context) return null;

  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = "high";
  context.drawImage(
    video,
    sourceX,
    sourceY,
    sourceSide,
    sourceSide,
    0,
    0,
    size,
    size,
  );
  return context;
}

export function decodeQRCodeImageData(imageData) {
  const result = jsQR(imageData.data, imageData.width, imageData.height, {
    inversionAttempts: "attemptBoth",
  });
  return result?.data || null;
}

export async function decodeQRCodeFrame(canvas, { nativeDetector = null } = {}) {
  if (nativeDetector) {
    try {
      const results = await nativeDetector.detect(canvas);
      if (results.length > 0 && results[0]?.rawValue) {
        return results[0].rawValue;
      }
    } catch {
      // jsQR below is the cross-browser and inverted-polarity fallback.
    }
  }

  const context = canvas.getContext("2d", { alpha: false, willReadFrequently: true });
  if (!context) return null;
  const imageData = context.getImageData(0, 0, canvas.width, canvas.height);
  return decodeQRCodeImageData(imageData);
}
