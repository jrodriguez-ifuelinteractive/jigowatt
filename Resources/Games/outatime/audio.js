'use strict';

/*
 * Tiny chiptune engine: pulse / triangle / noise voices synthesized with Web Audio,
 * a MIDI-style note sequencer with lookahead scheduling, and the game's sound effects.
 */
const Sound = (() => {
  let ctx = null, master, musicBus, sfxBus, noiseBuf;
  const waves = {};
  const vol = { music: 0.7, sfx: 0.8 };

  function init() {
    if (ctx) { if (ctx.state !== 'running') ctx.resume(); return; }
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    ctx = new AC();
    const comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -14; comp.ratio.value = 4; comp.attack.value = 0.004; comp.release.value = 0.2;
    master = ctx.createGain(); master.gain.value = 0.9;
    master.connect(comp); comp.connect(ctx.destination);
    musicBus = ctx.createGain(); sfxBus = ctx.createGain();
    musicBus.connect(master); sfxBus.connect(master);

    // A short slap-back echo gives the square waves some room.
    const delay = ctx.createDelay(1), fb = ctx.createGain(), wet = ctx.createGain(), tone = ctx.createBiquadFilter();
    delay.delayTime.value = 0.19; fb.gain.value = 0.25; wet.gain.value = 0.16;
    tone.type = 'lowpass'; tone.frequency.value = 3200;
    musicBus.connect(delay); delay.connect(tone); tone.connect(fb); fb.connect(delay); tone.connect(wet); wet.connect(master);

    // Big 80s plate-style reverb on the music, from a generated decaying-noise impulse.
    const verb = ctx.createConvolver(), verbWet = ctx.createGain();
    const len = Math.round(ctx.sampleRate * 2.2), ir = ctx.createBuffer(2, len, ctx.sampleRate);
    for (let c = 0; c < 2; c++) {
      const ch = ir.getChannelData(c);
      for (let i = 0; i < len; i++) ch[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3.2);
    }
    verb.buffer = ir; verbWet.gain.value = 0.22;
    musicBus.connect(verb); verb.connect(verbWet); verbWet.connect(master);
    // Sound effects share the reverb so they sit in the same space as the music.
    const sfxSend = ctx.createGain(); sfxSend.gain.value = 0.7;
    sfxBus.connect(sfxSend); sfxSend.connect(verb);

    noiseBuf = ctx.createBuffer(1, ctx.sampleRate, ctx.sampleRate);
    const d = noiseBuf.getChannelData(0);
    for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
    applyVolume();
  }

  function applyVolume() {
    if (!ctx) return;
    const t = ctx.currentTime;
    musicBus.gain.setTargetAtTime(vol.music * vol.music, t, 0.05);
    sfxBus.gain.setTargetAtTime(vol.sfx * vol.sfx, t, 0.02);
  }

  function setVolume(kind, v) { vol[kind] = Math.max(0, Math.min(1, v)); applyVolume(); }

  // Band-limited pulse wave with the given duty cycle (0.125, 0.25, 0.5 = NES-style).
  function pulse(duty) {
    if (!waves[duty]) {
      const n = 48, re = new Float32Array(n), im = new Float32Array(n);
      for (let k = 1; k < n; k++) re[k] = (2 / (k * Math.PI)) * Math.sin(k * Math.PI * duty);
      waves[duty] = ctx.createPeriodicWave(re, im);
    }
    return waves[duty];
  }

  const midiFreq = (m) => 440 * Math.pow(2, (m - 69) / 12);

  function tone(o) {
    if (!ctx) return;
    const t = o.time ?? ctx.currentTime;
    const osc = ctx.createOscillator();
    if (o.wave.startsWith('pulse')) osc.setPeriodicWave(pulse(+o.wave.slice(5) / 100));
    else osc.type = o.wave;
    osc.frequency.setValueAtTime(o.freq, t);
    if (o.detune) osc.detune.setValueAtTime(o.detune, t);
    if (o.slide) osc.frequency.exponentialRampToValueAtTime(o.slide, t + (o.slideTime ?? o.dur));

    const g = ctx.createGain();
    const a = o.attack ?? 0.004, dec = o.decay ?? 0.1, s = o.sustain ?? 0.6, r = o.release ?? 0.04, v = o.vol ?? 0.3;
    const dur = Math.max(o.dur, a);
    g.gain.setValueAtTime(0, t);
    g.gain.linearRampToValueAtTime(v, t + a);
    g.gain.setTargetAtTime(v * s, t + a, dec / 3);
    const atEnd = v * s + (v - v * s) * Math.exp(-(dur - a) / (dec / 3));
    g.gain.setValueAtTime(atEnd, t + dur);
    g.gain.linearRampToValueAtTime(0, t + dur + r);

    if (o.vibrato && dur > 0.22) {
      const lfo = ctx.createOscillator(), depth = ctx.createGain();
      lfo.frequency.value = 5.5;
      depth.gain.setValueAtTime(0, t);
      depth.gain.linearRampToValueAtTime(o.freq * 0.012, t + 0.25);
      lfo.connect(depth); depth.connect(osc.frequency);
      lfo.start(t); lfo.stop(t + dur + r + 0.05);
    }
    // Optional resonant filter with an envelope sweeping from `freq` toward `to`.
    let out = osc;
    if (o.filter) {
      const f = ctx.createBiquadFilter();
      f.type = o.filter.type ?? 'lowpass'; f.Q.value = o.filter.q ?? 1;
      f.frequency.setValueAtTime(o.filter.freq, t);
      if (o.filter.to) f.frequency.setTargetAtTime(o.filter.to, t + a, (o.filter.time ?? 0.1) / 3);
      osc.connect(f); out = f;
    }
    out.connect(g); g.connect(o.bus ?? sfxBus);
    osc.start(t); osc.stop(t + dur + r + 0.05);
  }

  function noise(o) {
    if (!ctx) return;
    const t = o.time ?? ctx.currentTime;
    const src = ctx.createBufferSource();
    src.buffer = noiseBuf;
    src.playbackRate.value = o.rate ?? 1;
    const f = ctx.createBiquadFilter();
    f.type = o.filter ?? 'highpass'; f.frequency.setValueAtTime(o.freq ?? 4000, t); f.Q.value = o.q ?? 0.8;
    if (o.sweep) f.frequency.exponentialRampToValueAtTime(o.sweep, t + o.dur);
    const g = ctx.createGain();
    g.gain.setValueAtTime(o.vol ?? 0.3, t);
    if (o.gate) {
      // Gated: hold the tail, then chop it off — the classic 80s snare.
      g.gain.linearRampToValueAtTime((o.vol ?? 0.3) * 0.6, t + o.dur - 0.012);
      g.gain.linearRampToValueAtTime(0, t + o.dur);
    } else {
      g.gain.exponentialRampToValueAtTime(0.0008, t + o.dur);
    }
    src.connect(f); f.connect(g); g.connect(o.bus ?? sfxBus);
    src.start(t, Math.random() * 0.5); src.stop(t + o.dur + 0.02);
  }

  /* ---------------- Instruments ---------------- */

  const M = (o) => tone({ bus: musicBus, ...o });
  const saw2 = (o, cents) => { M({ ...o, wave: 'sawtooth', detune: -cents }); M({ ...o, wave: 'sawtooth', detune: cents }); };

  const INSTRUMENTS = {
    // Detuned twin-saw "brass" lead.
    lead: (m, t, d) => saw2({ freq: midiFreq(m), time: t, dur: d * 0.92, vol: 0.075, attack: 0.012, decay: 0.3, sustain: 0.75, release: 0.08,
                              vibrato: true, filter: { freq: 4200, to: 2400, time: 0.3, q: 1.2 } }, 9),
    // Plucky 16th-note arpeggio.
    arp:  (m, t, d) => M({ wave: 'pulse25', freq: midiFreq(m), time: t, dur: d * 0.55, vol: 0.05, decay: 0.08, sustain: 0.3, release: 0.03,
                           filter: { freq: 5000, to: 1600, time: 0.08, q: 2 } }),
    // Warm detuned pad that swells in.
    pad:  (m, t, d) => saw2({ freq: midiFreq(m), time: t, dur: d * 0.98, vol: 0.022, attack: 0.35, decay: 0.6, sustain: 0.85, release: 0.45,
                              filter: { freq: 1100, q: 0.7 } }, 12),
    // Pulsing filtered-saw bass.
    bass: (m, t, d) => M({ wave: 'sawtooth', freq: midiFreq(m), time: t, dur: d * 0.8, vol: 0.2, decay: 0.12, sustain: 0.55, release: 0.03,
                           filter: { freq: 2200, to: 320, time: 0.14, q: 5 } }),
    drums: (n, t) => DRUMS[n] && DRUMS[n](t),
  };

  const DRUMS = {
    k:  (t) => { M({ wave: 'sine', freq: 150, slide: 40, slideTime: 0.13, time: t, dur: 0.16, vol: 0.75, decay: 0.12, sustain: 0.2 });
                 noise({ bus: musicBus, time: t, dur: 0.012, vol: 0.12, filter: 'lowpass', freq: 3000 }); },
    s:  (t) => { noise({ bus: musicBus, time: t, dur: 0.09, vol: 0.28, filter: 'bandpass', freq: 1800, q: 0.8 });
                 noise({ bus: musicBus, time: t, dur: 0.26, vol: 0.13, filter: 'lowpass', freq: 6500, gate: true });
                 M({ wave: 'triangle', freq: 210, slide: 150, time: t, dur: 0.07, vol: 0.2, decay: 0.05, sustain: 0.1 }); },
    h:  (t) => noise({ bus: musicBus, time: t, dur: 0.03, vol: 0.045, filter: 'highpass', freq: 8500 }),
    tl: (t) => M({ wave: 'sine', freq: 110, slide: 65, time: t, dur: 0.22, vol: 0.5, decay: 0.15, sustain: 0.2 }),
    tm: (t) => M({ wave: 'sine', freq: 150, slide: 90, time: t, dur: 0.2, vol: 0.45, decay: 0.14, sustain: 0.2 }),
    th: (t) => M({ wave: 'sine', freq: 200, slide: 120, time: t, dur: 0.18, vol: 0.4, decay: 0.12, sustain: 0.2 }),
  };

  /* ---------------- Sequencer ---------------- */

  const NOTE_INDEX = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };
  function noteToMidi(name) {
    const m = /^([A-G])([#b]?)(-?\d)$/.exec(name);
    if (!m) throw new Error('bad note ' + name);
    return 12 * (+m[3] + 1) + NOTE_INDEX[m[1]] + (m[2] === '#' ? 1 : m[2] === 'b' ? -1 : 0);
  }

  // "E5:1 B4:.5 r:.5 C4+E4:1" -> events. Drum tracks use names instead of notes.
  function compile(song) {
    const events = [];
    let length = 0;
    for (const track of song.tracks) {
      let beat = 0;
      for (const tok of track.notes.trim().split(/\s+/)) {
        const [name, durStr] = tok.split(':');
        const dur = parseFloat(durStr);
        if (name !== 'r') {
          const notes = track.inst === 'drums' ? name.split('+') : name.split('+').map(noteToMidi);
          for (const n of notes) events.push({ beat, dur, inst: track.inst, n });
        }
        beat += dur;
      }
      length = Math.max(length, beat);
    }
    events.sort((a, b) => a.beat - b.beat);
    return { events, length };
  }

  const seq = { song: null, events: [], length: 0, idx: 0, offset: 0, anchorBeat: 0, anchorTime: 0, bpm: 120, mul: 1, timer: null, paused: false };
  const secPerBeat = () => 60 / (seq.bpm * seq.mul);
  const beatTime = (b) => seq.anchorTime + (b - seq.anchorBeat) * secPerBeat();
  const nextBeat = () => (seq.events.length ? seq.events[seq.idx].beat + seq.offset : 0);

  // Re-anchor the clock at the next unscheduled event so tempo changes never glitch.
  function reanchor() {
    const b = nextBeat();
    seq.anchorTime = beatTime(b);
    seq.anchorBeat = b;
  }

  function tick() {
    if (!ctx || !seq.events.length) return;
    const now = ctx.currentTime, horizon = now + 0.18;
    for (let guard = 0; guard < 2000; guard++) {
      const ev = seq.events[seq.idx];
      const t = beatTime(ev.beat + seq.offset);
      if (t > horizon) break;
      if (t >= now - 0.03) INSTRUMENTS[ev.inst](ev.n, t, ev.dur * secPerBeat());
      seq.idx++;
      if (seq.idx >= seq.events.length) {
        seq.idx = 0;
        seq.offset += seq.length;
      }
    }
  }

  function playSong(song) {
    stopSong();
    init();
    if (!ctx || !song) return;
    const c = compile(song);
    Object.assign(seq, { song, events: c.events, length: c.length, idx: 0, offset: 0, anchorBeat: 0, anchorTime: ctx.currentTime + 0.08, bpm: song.bpm, paused: false });
    seq.timer = setInterval(tick, 25);
    tick();
  }

  function stopSong() {
    clearInterval(seq.timer);
    seq.timer = null;
    seq.song = null;
    seq.events = [];
  }

  function pauseSong() {
    if (!seq.timer) return;
    clearInterval(seq.timer); seq.timer = null; seq.paused = true;
  }

  function resumeSong() {
    if (!seq.paused || !seq.song || !ctx) return;
    seq.anchorBeat = nextBeat();
    seq.anchorTime = ctx.currentTime + 0.06;
    seq.paused = false;
    seq.timer = setInterval(tick, 25);
    tick();
  }

  function setTempo(mul) {
    if (Math.abs(mul - seq.mul) < 0.001) return;
    if (seq.song && ctx) reanchor();
    seq.mul = mul;
  }

  /* ---------------- Sound effects ---------------- */

  // Built from the soundtrack's synths and tuned to A minor so they sit over the music.
  const N = noteToMidi;
  const S = (o) => tone({ bus: sfxBus, ...o });
  const hz = (x) => midiFreq(N(x));

  // Detuned twin-saw chord stab, like the lead.
  function stab(notes, t, o = {}) {
    for (const x of notes) for (const c of [-9, 9]) {
      S({ wave: 'sawtooth', freq: hz(x), detune: c, time: t, dur: o.dur ?? 0.12, vol: o.vol ?? 0.045,
          attack: o.attack ?? 0.005, decay: o.decay ?? 0.18, sustain: o.sustain ?? 0.4, release: o.release ?? 0.15, vibrato: o.vibrato,
          filter: { freq: o.cut ?? 4500, to: o.cutTo ?? 900, time: o.cutTime ?? 0.25, q: o.q ?? 2 } });
    }
  }
  // Short filtered pluck, like the arpeggio.
  const pluck = (x, t, o = {}) => S({ wave: 'pulse25', freq: hz(x), time: t, dur: o.dur ?? 0.05, vol: o.vol ?? 0.09,
    decay: 0.06, sustain: 0.25, release: 0.05, filter: { freq: o.cut ?? 5000, to: 1100, time: 0.08, q: 3 } });
  const kick = (t, v = 0.7) => S({ wave: 'sine', freq: 160, slide: 38, slideTime: 0.14, time: t, dur: 0.18, vol: v, decay: 0.12, sustain: 0.2 });
  const gatedSnare = (t, v = 1) => {
    noise({ time: t, dur: 0.09, vol: 0.26 * v, filter: 'bandpass', freq: 1800, q: 0.8 });
    noise({ time: t, dur: 0.28, vol: 0.12 * v, filter: 'lowpass', freq: 6500, gate: true });
  };
  const riser = (t, dur, v = 0.12) => noise({ time: t, dur, vol: v, filter: 'bandpass', freq: 400, sweep: 9000, q: 2 });

  const sfx = {
    move:    () => pluck('A5', ctx.currentTime, { dur: 0.025, vol: 0.05, cut: 3500 }),
    rotate:  () => S({ wave: 'sawtooth', freq: hz('E5'), slide: hz('A5'), slideTime: 0.05, dur: 0.06, vol: 0.06, decay: 0.05, sustain: 0.4,
                       filter: { freq: 900, to: 5200, time: 0.05, q: 8 } }),
    soft:    () => noise({ dur: 0.025, vol: 0.035, filter: 'highpass', freq: 7000 }),
    lock:    () => { const t = ctx.currentTime;
                     S({ wave: 'sawtooth', freq: hz('A2'), time: t, dur: 0.07, vol: 0.14, decay: 0.06, sustain: 0.2, filter: { freq: 1400, to: 180, time: 0.06, q: 4 } });
                     noise({ time: t, dur: 0.04, vol: 0.06, filter: 'lowpass', freq: 2000 }); },
    hard:    () => { const t = ctx.currentTime;
                     kick(t, 0.8);
                     gatedSnare(t, 0.7);
                     S({ wave: 'sawtooth', freq: hz('A3'), slide: hz('A1'), slideTime: 0.15, time: t, dur: 0.16, vol: 0.1, decay: 0.1, sustain: 0.3,
                         filter: { freq: 2500, to: 200, time: 0.12, q: 5 } }); },
    hold:    () => { const t = ctx.currentTime; pluck('E5', t); pluck('A5', t + 0.06, { dur: 0.08 }); },
    clear:   (n) => { const t = ctx.currentTime;
                      ['A4', 'C5', 'E5', 'A5', 'C6'].slice(0, n + 2).forEach((x, i) => stab([x], t + i * 0.055, { dur: 0.14, vol: 0.05, cut: 6000 }));
                      riser(t, 0.3, 0.08); },
    quad:    () => { const t = ctx.currentTime;
                     riser(t, 0.25, 0.1);
                     stab(['A4', 'C5', 'E5', 'B5'], t + 0.08, { dur: 0.5, vol: 0.04, cut: 7000, cutTo: 1200, cutTime: 0.6, vibrato: true });
                     stab(['A5'], t + 0.08, { dur: 0.5, vol: 0.035, cut: 8000, cutTo: 1500, cutTime: 0.6 });
                     kick(t + 0.08, 0.9); gatedSnare(t + 0.08, 1.1);
                     S({ wave: 'sawtooth', freq: hz('A1'), time: t + 0.08, dur: 0.5, vol: 0.18, decay: 0.3, sustain: 0.4, filter: { freq: 900, to: 150, time: 0.4, q: 3 } }); },
    tspin:   () => { const t = ctx.currentTime;
                     // Resonant filter "laser" sweep.
                     for (const [x, d] of [['E4', 0], ['A4', 0.09]]) {
                       S({ wave: 'sawtooth', freq: hz(x), time: t + d, dur: 0.22, vol: 0.07, decay: 0.2, sustain: 0.5, release: 0.1,
                           filter: { freq: 250, to: 7000, time: 0.2, q: 14 } });
                     } },
    levelup: () => { const t = ctx.currentTime;
                     ['A4', 'C5', 'E5', 'G5', 'A5'].forEach((x, i) => pluck(x, t + i * 0.07, { dur: 0.09 }));
                     stab(['A4', 'C5', 'E5', 'A5'], t + 0.35, { dur: 0.6, vol: 0.035, attack: 0.02, cut: 6000, cutTo: 1400, cutTime: 0.7, vibrato: true }); },
    perfect: () => { const t = ctx.currentTime;
                     [[['F4', 'A4', 'C5'], 0], [['G4', 'B4', 'D5'], 0.18], [['A4', 'C5', 'E5', 'A5'], 0.36]].forEach(([c, d], i) =>
                       stab(c, t + d, { dur: i === 2 ? 0.7 : 0.14, vol: 0.04, cut: 6500, vibrato: i === 2 }));
                     kick(t + 0.36); gatedSnare(t + 0.36); },
    count:   (go) => { const t = ctx.currentTime;
                       if (go) { stab(['A4', 'E5', 'A5'], t, { dur: 0.35, vol: 0.045, cut: 7000 }); kick(t); gatedSnare(t, 0.8); }
                       else pluck('A5', t, { dur: 0.1, vol: 0.1 }); },
    over:    () => { const t = ctx.currentTime;
                     ['E5', 'C5', 'A4', 'G4', 'E4'].forEach((x, i) =>
                       stab([x], t + i * 0.16, { dur: 0.14, vol: 0.05, cut: 4000 - i * 500, cutTo: 700 }));
                     // Final chord winds down like a tape stop.
                     for (const x of ['A2', 'A3', 'C4', 'E4']) for (const c of [-10, 10]) {
                       S({ wave: 'sawtooth', freq: hz(x), slide: hz(x) * 0.5, slideTime: 1.2, detune: c, time: t + 0.8, dur: 1.2, vol: 0.035,
                           attack: 0.01, decay: 0.8, sustain: 0.7, release: 0.2, filter: { freq: 3000, to: 300, time: 1.2, q: 2 } });
                     }
                     kick(t + 0.8, 0.6); },
    thunder: () => { noise({ dur: 1.6, vol: 0.32, filter: 'lowpass', freq: 900, sweep: 120, rate: 0.5 });
                     noise({ dur: 0.25, vol: 0.2, filter: 'highpass', freq: 2500 }); },
    timejump:() => { const t = ctx.currentTime;
                     for (const c of [-12, 12]) S({ wave: 'sawtooth', freq: 70, slide: 1400, slideTime: 0.55, detune: c, time: t, dur: 0.6, vol: 0.07,
                                                    decay: 0.5, sustain: 0.8, filter: { freq: 400, to: 8000, time: 0.5, q: 6 } });
                     riser(t, 0.55, 0.14);
                     kick(t + 0.58, 1); gatedSnare(t + 0.58, 1.3);
                     noise({ time: t + 0.58, dur: 1.2, vol: 0.3, filter: 'lowpass', freq: 3000, sweep: 100 });
                     stab(['A4', 'C5', 'E5', 'A5'], t + 0.58, { dur: 0.8, vol: 0.04, cut: 8000, cutTo: 1200, cutTime: 0.9, vibrato: true }); },
    menu:    () => pluck('E6', ctx.currentTime, { dur: 0.03, vol: 0.05 }),
    select:  () => { const t = ctx.currentTime; pluck('A5', t, { vol: 0.08 }); pluck('E6', t + 0.06, { dur: 0.08, vol: 0.08 }); },
    pause:   () => { const t = ctx.currentTime; pluck('E5', t); pluck('A4', t + 0.07, { dur: 0.08 }); },
  };

  function play(name, arg) {
    if (!ctx || ctx.state !== 'running' || !sfx[name]) return;
    sfx[name](arg);
  }

  return { init, play, playSong, stopSong, pauseSong, resumeSong, setTempo, setVolume };
})();
