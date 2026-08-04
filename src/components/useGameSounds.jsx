// Fully reworked Web Audio API sound system
export function useGameSounds() {
  const getCtx = () => {
    if (!window._audioCtx) {
      window._audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    }
    return window._audioCtx;
  };

  const play = (fn) => {
    try {
      const ctx = getCtx();
      if (ctx.state === "suspended") ctx.resume();
      fn(ctx);
    } catch {}
  };

  // Short UI click
  const click = () => play((ctx) => {
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    o.connect(g); g.connect(ctx.destination);
    o.frequency.setValueAtTime(900, ctx.currentTime);
    o.frequency.exponentialRampToValueAtTime(700, ctx.currentTime + 0.06);
    g.gain.setValueAtTime(0.12, ctx.currentTime);
    g.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.08);
    o.start(); o.stop(ctx.currentTime + 0.08);
  });

  // Player joined — soft ascending ping
  const playerJoined = () => play((ctx) => {
    [440, 550, 660].forEach((freq, i) => {
      const o = ctx.createOscillator();
      const g = ctx.createGain();
      o.connect(g); g.connect(ctx.destination);
      o.type = "sine";
      o.frequency.value = freq;
      const t = ctx.currentTime + i * 0.07;
      g.gain.setValueAtTime(0.1, t);
      g.gain.exponentialRampToValueAtTime(0.001, t + 0.12);
      o.start(t); o.stop(t + 0.12);
    });
  });

  // New round start — dramatic synth stab
  const roundStart = () => play((ctx) => {
    // Bass hit
    const bass = ctx.createOscillator();
    const bassGain = ctx.createGain();
    bass.connect(bassGain); bassGain.connect(ctx.destination);
    bass.type = "sawtooth";
    bass.frequency.setValueAtTime(100, ctx.currentTime);
    bass.frequency.exponentialRampToValueAtTime(60, ctx.currentTime + 0.3);
    bassGain.gain.setValueAtTime(0.25, ctx.currentTime);
    bassGain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.4);
    bass.start(); bass.stop(ctx.currentTime + 0.4);

    // Bright stab
    [523, 659, 784].forEach((freq, i) => {
      const o = ctx.createOscillator();
      const g = ctx.createGain();
      o.connect(g); g.connect(ctx.destination);
      o.type = "square";
      o.frequency.value = freq;
      const t = ctx.currentTime + i * 0.06;
      g.gain.setValueAtTime(0.12, t);
      g.gain.exponentialRampToValueAtTime(0.001, t + 0.18);
      o.start(t); o.stop(t + 0.18);
    });
  });

  // Alert / vote request — urgent blip
  const alert = () => play((ctx) => {
    [0, 0.15].forEach((delay) => {
      const o = ctx.createOscillator();
      const g = ctx.createGain();
      o.connect(g); g.connect(ctx.destination);
      o.type = "square";
      o.frequency.setValueAtTime(880, ctx.currentTime + delay);
      o.frequency.exponentialRampToValueAtTime(440, ctx.currentTime + delay + 0.1);
      g.gain.setValueAtTime(0.14, ctx.currentTime + delay);
      g.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + delay + 0.15);
      o.start(ctx.currentTime + delay);
      o.stop(ctx.currentTime + delay + 0.15);
    });
  });

  // Vote submitted — soft low thud
  const vote = () => play((ctx) => {
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    o.connect(g); g.connect(ctx.destination);
    o.type = "sine";
    o.frequency.setValueAtTime(500, ctx.currentTime);
    o.frequency.exponentialRampToValueAtTime(250, ctx.currentTime + 0.18);
    g.gain.setValueAtTime(0.18, ctx.currentTime);
    g.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.22);
    o.start(); o.stop(ctx.currentTime + 0.22);
  });

  // Success / confirm
  const success = () => play((ctx) => {
    [523, 659, 784].forEach((freq, i) => {
      const o = ctx.createOscillator();
      const g = ctx.createGain();
      o.connect(g); g.connect(ctx.destination);
      o.frequency.value = freq;
      o.type = "sine";
      const t = ctx.currentTime + i * 0.1;
      g.gain.setValueAtTime(0.18, t);
      g.gain.exponentialRampToValueAtTime(0.001, t + 0.15);
      o.start(t); o.stop(t + 0.15);
    });
  });

  // Win fanfare — triumphant ascending melody
  const win = () => play((ctx) => {
    const melody = [523, 659, 784, 1047, 1047];
    const durations = [0.12, 0.12, 0.12, 0.12, 0.3];
    melody.forEach((freq, i) => {
      const o = ctx.createOscillator();
      const g = ctx.createGain();
      o.connect(g); g.connect(ctx.destination);
      o.frequency.value = freq;
      o.type = i === 4 ? "sine" : "square";
      const t = ctx.currentTime + melody.slice(0, i).reduce((a, _, j) => a + durations[j], 0);
      g.gain.setValueAtTime(i === 4 ? 0.25 : 0.15, t);
      g.gain.exponentialRampToValueAtTime(0.001, t + durations[i] + 0.1);
      o.start(t); o.stop(t + durations[i] + 0.15);
    });
  });

  // Lose — descending minor chord
  const lose = () => play((ctx) => {
    [400, 336, 252, 200].forEach((freq, i) => {
      const o = ctx.createOscillator();
      const g = ctx.createGain();
      o.connect(g); g.connect(ctx.destination);
      o.frequency.value = freq;
      o.type = "sawtooth";
      const t = ctx.currentTime + i * 0.14;
      g.gain.setValueAtTime(0.16, t);
      g.gain.exponentialRampToValueAtTime(0.001, t + 0.25);
      o.start(t); o.stop(t + 0.3);
    });
  });

  // Barrel drum / roulette spin thud
  const barrel = () => play((ctx) => {
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    o.connect(g); g.connect(ctx.destination);
    o.type = "sine";
    o.frequency.setValueAtTime(150, ctx.currentTime);
    o.frequency.exponentialRampToValueAtTime(60, ctx.currentTime + 0.3);
    g.gain.setValueAtTime(0.28, ctx.currentTime);
    g.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.4);
    o.start(); o.stop(ctx.currentTime + 0.4);
  });

  // Card flip — short snap
  const cardFlip = () => play((ctx) => {
    const bufferSize = ctx.sampleRate * 0.05;
    const buffer = ctx.createBuffer(1, bufferSize, ctx.sampleRate);
    const data = buffer.getChannelData(0);
    for (let i = 0; i < bufferSize; i++) data[i] = (Math.random() * 2 - 1) * (1 - i / bufferSize);
    const source = ctx.createBufferSource();
    const g = ctx.createGain();
    const filter = ctx.createBiquadFilter();
    filter.type = "highpass";
    filter.frequency.value = 2000;
    source.buffer = buffer;
    source.connect(filter); filter.connect(g); g.connect(ctx.destination);
    g.gain.setValueAtTime(0.3, ctx.currentTime);
    g.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.05);
    source.start(); source.stop(ctx.currentTime + 0.05);
  });

  return { click, playerJoined, roundStart, alert, vote, success, win, lose, barrel, cardFlip };
}