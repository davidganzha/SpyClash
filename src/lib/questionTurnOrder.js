function normalizePlayerCount(playerCount) {
  const count = Number(playerCount);
  return Number.isInteger(count) && count >= 0 ? count : 0;
}

export function createQuestionTurnOrder(playerCount, random = Math.random) {
  const order = Array.from({ length: normalizePlayerCount(playerCount) }, (_, index) => index);
  for (let index = order.length - 1; index > 0; index -= 1) {
    const sample = Number(random());
    const boundedSample = Number.isFinite(sample)
      ? Math.min(Math.max(sample, 0), 1 - Number.EPSILON)
      : 0;
    const swapIndex = Math.floor(boundedSample * (index + 1));
    [order[index], order[swapIndex]] = [order[swapIndex], order[index]];
  }
  return order;
}

export function questionPairForStep(order, step) {
  if (!Array.isArray(order) || order.length < 2) return null;
  const numericStep = Number(step);
  const safeStep = Number.isInteger(numericStep) ? numericStep : 0;
  const askerPosition = ((safeStep % order.length) + order.length) % order.length;
  const answererPosition = (askerPosition + 1) % order.length;
  return {
    askerIndex: order[askerPosition],
    answererIndex: order[answererPosition],
  };
}

export function nextQuestionTurnStep(order, step) {
  if (!Array.isArray(order) || order.length < 2) return 0;
  const numericStep = Number(step);
  const safeStep = Number.isInteger(numericStep) ? numericStep : 0;
  return (((safeStep + 1) % order.length) + order.length) % order.length;
}
