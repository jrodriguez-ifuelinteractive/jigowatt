'use strict';

(() => {
  /* ================= Rules ================= */

  const COLS = 10, ROWS = 22, HIDDEN = 2, VIS = ROWS - HIDDEN;
  const TYPES = ['I', 'O', 'T', 'S', 'Z', 'J', 'L'];
  const SHAPES = {
    I: [[0, 0, 0, 0], [1, 1, 1, 1], [0, 0, 0, 0], [0, 0, 0, 0]],
    O: [[1, 1], [1, 1]],
    T: [[0, 1, 0], [1, 1, 1], [0, 0, 0]],
    S: [[0, 1, 1], [1, 1, 0], [0, 0, 0]],
    Z: [[1, 1, 0], [0, 1, 1], [0, 0, 0]],
    J: [[1, 0, 0], [1, 1, 1], [0, 0, 0]],
    L: [[0, 0, 1], [1, 1, 1], [0, 0, 0]],
  };
  const COLORS = { I: '#2de2ff', O: '#ffd43b', T: '#b56cff', S: '#4ade5a', Z: '#ff4d6d', J: '#4c7dff', L: '#ff9933', G: '#5d6380' };

  const rotateCW = (m) => m.map((row, y) => row.map((_, x) => m[m.length - 1 - x][y]));
  const CELLS = {};
  for (const t of TYPES) {
    let m = SHAPES[t];
    CELLS[t] = [];
    for (let r = 0; r < 4; r++) {
      const cells = [];
      m.forEach((row, y) => row.forEach((v, x) => v && cells.push([x, y])));
      CELLS[t].push(cells);
      m = rotateCW(m);
    }
  }

  // SRS wall kicks (guideline tables use y-up; flip to our y-down grid).
  const flip = (a) => a.map(([x, y]) => [x, -y]);
  const KICKS = {
    '0>1': flip([[0, 0], [-1, 0], [-1, 1], [0, -2], [-1, -2]]),
    '1>0': flip([[0, 0], [1, 0], [1, -1], [0, 2], [1, 2]]),
    '1>2': flip([[0, 0], [1, 0], [1, -1], [0, 2], [1, 2]]),
    '2>1': flip([[0, 0], [-1, 0], [-1, 1], [0, -2], [-1, -2]]),
    '2>3': flip([[0, 0], [1, 0], [1, 1], [0, -2], [1, -2]]),
    '3>2': flip([[0, 0], [-1, 0], [-1, -1], [0, 2], [-1, 2]]),
    '3>0': flip([[0, 0], [-1, 0], [-1, -1], [0, 2], [-1, 2]]),
    '0>3': flip([[0, 0], [1, 0], [1, 1], [0, -2], [1, -2]]),
  };
  const KICKS_I = {
    '0>1': flip([[0, 0], [-2, 0], [1, 0], [-2, -1], [1, 2]]),
    '1>0': flip([[0, 0], [2, 0], [-1, 0], [2, 1], [-1, -2]]),
    '1>2': flip([[0, 0], [-1, 0], [2, 0], [-1, 2], [2, -1]]),
    '2>1': flip([[0, 0], [1, 0], [-2, 0], [1, -2], [-2, 1]]),
    '2>3': flip([[0, 0], [2, 0], [-1, 0], [2, 1], [-1, -2]]),
    '3>2': flip([[0, 0], [-2, 0], [1, 0], [-2, -1], [1, 2]]),
    '3>0': flip([[0, 0], [1, 0], [-2, 0], [1, -2], [-2, 1]]),
    '0>3': flip([[0, 0], [-1, 0], [2, 0], [-1, 2], [2, -1]]),
  };

  const MAX_RESETS = 15, ARR = 0.033;
  // Soft drop is ~12 rows/s at low levels, never slower than normal gravity.
  const softInterval = (base) => Math.min(base, Math.max(base / 12, 0.08));
  // Seconds per row at each level: front-loaded so the first few levels are noticeably
  // faster than each other, then tightening toward near-instant drops by level 20.
  const SPEED = [0.7, 0.5, 0.36, 0.27, 0.2, 0.155, 0.12, 0.095, 0.075, 0.06,
                 0.05, 0.042, 0.035, 0.029, 0.024, 0.02, 0.016, 0.013, 0.01, 0.008];
  // Speed also creeps up with each line inside a level, so pressure builds continuously.
  function gravity() {
    const i = Math.min(level, 20) - 1;
    if (i >= SPEED.length - 1) return SPEED[SPEED.length - 1];
    return SPEED[i] * Math.pow(SPEED[i + 1] / SPEED[i], (lines % 10) / 10);
  }
  // Pieces lock faster from level 15 on.
  const lockDelay = () => 0.5 - Math.max(0, Math.min(level, 20) - 14) * 0.03;

  /* ================= Persistence ================= */

  const store = {
    get(key, fallback) { try { const v = localStorage.getItem('outatime.' + key); return v ? JSON.parse(v) : fallback; } catch { return fallback; } },
    set(key, v) { try { localStorage.setItem('outatime.' + key, JSON.stringify(v)); } catch {} },
  };
  const opts = Object.assign({ startLevel: 1, music: true, musicVol: 7, sfxVol: 8, ghost: false, shake: true, das: 167 }, store.get('options', {}));
  let highScores = store.get('scores', []);
  let lastName = store.get('name', '');

  /* ================= State ================= */

  let mode = 'title'; // title | countdown | playing | clearing | dying | over | paused
  let pausedFrom = null;
  let board, bag, queue, hold, holdUsed, cur;
  let score, shownScore, lines, level, combo, b2b, elapsed;
  let gravAcc, lockTimer, lockResets, lowestY, lastRotate, lastKick;
  let clearing = null, dying = null, countdown = 0;
  let danger = 0, stats;

  const input = { left: false, right: false, soft: false, dasDir: 0, dasTimer: 0, arrTimer: 0 };

  function emptyBoard() { return Array.from({ length: ROWS }, () => Array(COLS).fill(null)); }

  function nextFromBag() {
    if (!bag.length) {
      bag = TYPES.slice();
      for (let i = bag.length - 1; i > 0; i--) { const j = (Math.random() * (i + 1)) | 0; [bag[i], bag[j]] = [bag[j], bag[i]]; }
    }
    return bag.pop();
  }

  function newGame() {
    board = emptyBoard();
    bag = []; queue = [];
    for (let i = 0; i < 5; i++) queue.push(nextFromBag());
    hold = null; holdUsed = false; cur = null;
    score = 0; shownScore = 0; lines = 0; level = opts.startLevel; combo = -1; b2b = false; elapsed = 0;
    stats = { quads: 0, tspins: 0, maxCombo: 0, pieces: 0 };
    clearing = null; dying = null; danger = 0;
    particles.length = 0; popups.length = 0; trails.length = 0; flashes.length = 0;
    input.dasTimer = 0; input.arrTimer = 0;
    hideScreens();
    showControls(true);
    mode = 'countdown'; countdown = 0; lastCount = -1;
    Sound.setTempo(1);
    startMusic();
  }

  function fits(type, rot, x, y) {
    for (const [cx, cy] of CELLS[type][rot]) {
      const bx = x + cx, by = y + cy;
      if (bx < 0 || bx >= COLS || by >= ROWS) return false;
      if (by >= 0 && board[by][bx]) return false;
    }
    return true;
  }

  const grounded = () => !fits(cur.type, cur.rot, cur.x, cur.y + 1);

  function spawn(type) {
    // Spawn with the piece's top row on the first visible row, fully inside the well.
    const top = Math.min(...CELLS[type][0].map((c) => c[1]));
    // A soft drop held from the previous piece must be re-pressed for this one.
    cur = { type, rot: 0, x: type === 'O' ? 4 : 3, y: HIDDEN - top, softOk: !input.soft };
    lowestY = cur.y; lockTimer = 0; lockResets = 0; gravAcc = 0; lastRotate = false; lastKick = 0;
    if (!fits(cur.type, 0, cur.x, cur.y)) { gameOver(); return false; }
    // Charged auto-shift carries into the new piece.
    if (input.dasDir && input.dasTimer >= opts.das / 1000) while (move(input.dasDir, true));
    return true;
  }

  function spawnNext() {
    queue.push(nextFromBag());
    holdUsed = false;
    spawn(queue.shift());
  }

  function afterMove() {
    if (cur.y > lowestY) { lowestY = cur.y; lockResets = 0; lockTimer = 0; }
    else if (grounded() && lockResets < MAX_RESETS) { lockTimer = 0; lockResets++; }
  }

  function move(dx, quiet) {
    if (!fits(cur.type, cur.rot, cur.x + dx, cur.y)) return false;
    cur.x += dx; lastRotate = false;
    afterMove();
    if (!quiet) Sound.play('move');
    return true;
  }

  function rotate(dir) {
    if (cur.type === 'O') { Sound.play('rotate'); return; }
    const to = (cur.rot + dir + 4) % 4;
    const kicks = (cur.type === 'I' ? KICKS_I : KICKS)[`${cur.rot}>${to}`];
    for (let i = 0; i < kicks.length; i++) {
      const [dx, dy] = kicks[i];
      if (fits(cur.type, to, cur.x + dx, cur.y + dy)) {
        cur.x += dx; cur.y += dy; cur.rot = to;
        lastRotate = true; lastKick = i;
        afterMove();
        Sound.play('rotate');
        return;
      }
    }
  }

  function hardDrop() {
    const startY = cur.y;
    while (fits(cur.type, cur.rot, cur.x, cur.y + 1)) cur.y++;
    const dist = cur.y - startY;
    if (dist > 0) lastRotate = false;
    score += dist * 2;
    // Light streaks from where the piece was to where it landed.
    const cols = {};
    for (const [cx, cy] of CELLS[cur.type][cur.rot]) {
      const x = cur.x + cx;
      cols[x] = Math.min(cols[x] ?? 99, cy);
    }
    for (const x in cols) {
      trails.push({ x: +x, y0: startY + cols[x], y1: cur.y + cols[x], life: 1 });
      if (dist > 2) burst(+x, cur.y + cols[x], '#ff9a1f', 2);
    }
    shake(dist > 2 ? 5 : 2.5);
    Sound.play('hard');
    lock();
  }

  function holdPiece() {
    if (holdUsed) return;
    const t = cur.type;
    if (hold) { const h = hold; hold = t; spawn(h); }
    else { hold = t; queue.push(nextFromBag()); spawn(queue.shift()); }
    holdUsed = true;
    Sound.play('hold');
  }

  function tSpin() {
    if (cur.type !== 'T' || !lastRotate) return null;
    const cx = cur.x + 1, cy = cur.y + 1;
    const occ = (x, y) => x < 0 || x >= COLS || y >= ROWS || (y >= 0 && !!board[y][x]);
    const c = [occ(cx - 1, cy - 1), occ(cx + 1, cy - 1), occ(cx + 1, cy + 1), occ(cx - 1, cy + 1)];
    if (c.filter(Boolean).length < 3) return null;
    const [f1, f2] = [[0, 1], [1, 2], [2, 3], [3, 0]][cur.rot];
    return (c[f1] && c[f2]) || lastKick === 4 ? 'full' : 'mini';
  }

  function lock() {
    const spin = tSpin();
    let aboveTop = true;
    for (const [cx, cy] of CELLS[cur.type][cur.rot]) {
      const x = cur.x + cx, y = cur.y + cy;
      if (y >= 0) board[y][x] = cur.type;
      if (y >= HIDDEN) aboveTop = false;
      flashes.push({ x, y, life: 1 });
    }
    stats.pieces++;
    Sound.play('lock');
    if (aboveTop) { cur = null; gameOver(); return; }

    const full = [];
    for (let y = 0; y < ROWS; y++) if (board[y].every(Boolean)) full.push(y);
    const perfect = full.length > 0 && board.every((row, y) => full.includes(y) || row.every((c) => !c));
    score += award(full.length, spin, perfect);
    cur = null;

    if (full.length) {
      mode = 'clearing';
      clearing = { rows: full, t: 0, dur: full.length === 4 ? 0.5 : 0.36 };
      for (const y of full) for (let x = 0; x < COLS; x++) burst(x, y, COLORS[board[y][x]], full.length === 4 ? 5 : 3);
      if (full.length === 4) shake(9);
    } else {
      spawnNext();
    }
  }

  function award(n, spin, perfect) {
    let base, label;
    if (spin === 'full') { base = [400, 800, 1200, 1600][n]; label = 'T-SPIN' + ['', ' SINGLE', ' DOUBLE', ' TRIPLE'][n]; }
    else if (spin === 'mini') { base = [100, 200, 400][n] ?? 400; label = 'MINI T-SPIN' + ['', ' SINGLE', ' DOUBLE'][n]; }
    else { base = [0, 100, 300, 500, 800][n]; label = ['', 'SINGLE', 'DOUBLE', 'TRIPLE', 'QUAD'][n]; }

    let pts = base * level;
    const lines_ = [];
    if (n > 0) {
      const difficult = n === 4 || !!spin;
      if (difficult && b2b) { pts = Math.floor(pts * 1.5); lines_.push(['BACK-TO-BACK', '#ffd43b', 0.55]); }
      b2b = difficult;
      combo++;
      if (combo > 0) { pts += 50 * combo * level; lines_.push([`COMBO ×${combo}`, '#7cf0ff', 0.55]); stats.maxCombo = Math.max(stats.maxCombo, combo); }
    } else {
      combo = -1;
    }
    if (perfect) {
      pts += ([0, 800, 1200, 1800, 2000][n] + (n === 4 && b2b ? 1200 : 0)) * level;
      lines_.unshift(['PERFECT CLEAR', '#ffffff', 0.85], ['TIME TRAVELER!', '#ff3b3b', 0.6]);
      setTimeout(() => Sound.play('perfect'), 250);
    }

    if (spin) stats.tspins++;
    if (n === 4) stats.quads++;
    if (spin) Sound.play('tspin');
    if (n === 4) Sound.play('quad'); else if (n > 0) Sound.play('clear', n);

    if (label && (n > 0 || spin)) {
      const color = spin ? COLORS.T : n === 4 ? COLORS.I : '#ffffff';
      popup(label, color, n === 4 || spin === 'full' ? 1 : 0.7);
    }
    if (n === 4) lines_.unshift(['1.21 GIGAWATTS!', '#ffb020', 0.55]);
    if (spin === 'full' && n > 0) lines_.unshift(['GREAT SCOTT!', '#ff9a1f', 0.55]);
    for (const [text, color, size] of lines_) popup(text, color, size);
    if (pts > 0 && n > 0) popup('+' + pts.toLocaleString(), '#c9cff7', 0.5);

    if (n > 0) {
      lines += n;
      const newLevel = opts.startLevel + Math.floor(lines / 10);
      if (newLevel > level) {
        level = newLevel;
        levelFlash = 1;
        // Hit 88 MPH: lightning, a flash, and fire down the road.
        setTimeout(() => {
          timeJump = 1; strike(); shake(6);
          Sound.play('timejump');
          popup('88 MPH', '#ff6a4d', 0.9);
          popup(`LEVEL ${level}`, levelColor(level, 70), 0.9);
        }, 180);
      }
    }
    return pts;
  }

  function finishClear() {
    const rows = clearing.rows;
    const kept = board.filter((_, y) => !rows.includes(y));
    board = [...Array.from({ length: rows.length }, () => Array(COLS).fill(null)), ...kept];
    clearing = null;
    mode = 'playing';
    spawnNext();
  }

  function gameOver() {
    mode = 'dying';
    dying = { t: 0, row: ROWS - 1 };
    Sound.stopSong();
    Sound.play('over');
    shake(8);
    showControls(false);
  }

  function finishGameOver() {
    mode = 'over';
    showGameOver();
  }

  /* ================= Effects ================= */

  const particles = [], popups = [], trails = [], flashes = [];
  let shakeMag = 0, levelFlash = 0;

  function shake(m) { if (opts.shake) shakeMag = Math.max(shakeMag, m); }

  function burst(x, y, color, n) {
    for (let i = 0; i < n; i++) {
      particles.push({
        x: x + 0.5 + (Math.random() - 0.5) * 0.6, y: y + 0.5 + (Math.random() - 0.5) * 0.6,
        vx: (Math.random() - 0.5) * 16 + (x - 4.5) * 1.6, vy: -Math.random() * 14 - 4,
        life: 1, decay: 0.7 + Math.random() * 0.8, size: 0.12 + Math.random() * 0.22, color,
      });
    }
  }

  function popup(text, color, size) {
    for (const p of popups) p.target -= 1;
    while (popups.length > 5) popups.shift();
    popups.push({ text, color, size, t: 0, life: 1.6, target: 0, y: 0.6 });
  }

  /* ================= Rendering (ASCII terminal) ================= */

  const canvas = document.getElementById('game');
  const g = canvas.getContext('2d');
  const MONO = '"SF Mono", Menlo, Monaco, monospace';

  // Everything is laid out on a terminal character grid.
  const GW = 76, GH = 26;
  const BOARD_COL = 28, BOARD_ROW = 2, LEFT_COL = 2, RIGHT_COL = 54;
  const CENTER_COL = BOARD_COL + 12;
  const TERM = {
    bg: '#07090a', fg: '#c8d6c8', dim: '#4d5e52', faint: '#1e2a22',
    green: '#3dff6e', red: '#ff3b3b', amber: '#ffb020', blue: '#5c9dff', white: '#f4fff4',
  };
  let W, H, dpr, cw, ch, fs, ox, oy, scanlines, time = 0;
  let bolt = null, nextBolt = 5, timeJump = 0, shownMph = 0;

  function hexRgb(h) { const n = parseInt(h.slice(1), 16); return [n >> 16, (n >> 8) & 255, n & 255]; }
  function rgba(h, a) { const [r, gg, b] = hexRgb(h); return `rgba(${r},${gg},${b},${a})`; }
  const levelColor = () => TERM.amber;

  // 5-row block letters for the title banner and the countdown.
  const BIG = {
    O: [' ███ ', '█   █', '█   █', '█   █', ' ███ '],
    U: ['█   █', '█   █', '█   █', '█   █', ' ███ '],
    T: ['█████', '  █  ', '  █  ', '  █  ', '  █  '],
    A: [' ███ ', '█   █', '█████', '█   █', '█   █'],
    I: ['███', ' █ ', ' █ ', ' █ ', '███'],
    M: ['█   █', '██ ██', '█ █ █', '█   █', '█   █'],
    E: ['█████', '█    ', '████ ', '█    ', '█████'],
    G: [' ████', '█    ', '█  ██', '█   █', ' ███ '],
    1: [' █ ', '██ ', ' █ ', ' █ ', '███'],
    2: ['████ ', '    █', ' ███ ', '█    ', '█████'],
    3: ['████ ', '    █', ' ███ ', '    █', '████ '],
    '!': ['█', '█', '█', ' ', '█'],
  };
  const bigText = (s) => [0, 1, 2, 3, 4].map((r) => [...s].map((c) => BIG[c][r]).join(' '));

  function resize() {
    dpr = window.devicePixelRatio || 1;
    W = window.innerWidth; H = window.innerHeight;
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    canvas.style.width = W + 'px'; canvas.style.height = H + 'px';
    g.font = `100px ${MONO}`;
    const ratio = g.measureText('M').width / 100;
    const top = 28; // clear the window's traffic lights
    fs = Math.max(7, Math.min((W - 16) / (GW * ratio), (H - top - 8) / (GH * 1.18)));
    cw = fs * ratio; ch = fs * 1.18;
    ox = Math.round((W - GW * cw) / 2);
    oy = Math.round(top + (H - top - GH * ch) / 2);
    // CRT scanlines as a repeating pattern.
    const p = document.createElement('canvas');
    p.width = 1; p.height = Math.max(3, Math.round(3 * dpr));
    const pg = p.getContext('2d');
    pg.fillStyle = 'rgba(0,0,0,0.22)'; pg.fillRect(0, 0, 1, Math.max(1, Math.round(dpr)));
    scanlines = g.createPattern(p, 'repeat');
  }

  function put(col, row, text, color = TERM.fg, o = {}) {
    const x = ox + col * cw, y = oy + row * ch;
    if (o.bg) { g.fillStyle = o.bg; g.fillRect(x, y, text.length * cw + 0.5, ch + 0.5); }
    g.globalAlpha = o.alpha ?? 1;
    g.font = `${o.bold ? 700 : 500} ${fs}px ${MONO}`;
    g.fillStyle = color;
    if (o.glow) { g.shadowColor = color; g.shadowBlur = o.glow; }
    g.fillText(text, x, y + ch / 2 + fs * 0.04);
    if (o.glow) g.shadowBlur = 0;
    g.globalAlpha = 1;
  }

  function box(col, row, w, h, title, color = TERM.fg) {
    put(col, row, '┌' + '─'.repeat(w - 2) + '┐', TERM.dim);
    for (let r = 1; r < h - 1; r++) { put(col, row + r, '│', TERM.dim); put(col + w - 1, row + r, '│', TERM.dim); }
    put(col, row + h - 1, '└' + '─'.repeat(w - 2) + '┘', TERM.dim);
    if (title) put(col + 2, row, ` ${title} `, color, { bold: true, bg: TERM.bg });
  }

  // Draws a tetromino as "[]" pairs, centered in a span of columns.
  function piece(type, col, span, row, alpha = 1) {
    const cells = CELLS[type][0];
    const xs = cells.map((c) => c[0]), ys = cells.map((c) => c[1]);
    const minX = Math.min(...xs), minY = Math.min(...ys), w = (Math.max(...xs) - minX + 1) * 2;
    const c0 = col + Math.floor((span - w) / 2);
    for (const [x, y] of cells) put(c0 + (x - minX) * 2, row + y - minY, '[]', COLORS[type], { alpha, bold: true });
  }

  // Seven-segment style readout: dim "8"s behind a glowing value, right-aligned.
  function readout(rightCol, row, text, color, digits) {
    const ghost = '8'.repeat(Math.max(digits, text.length));
    put(rightCol - ghost.length, row, ghost, color, { alpha: 0.12, bold: true });
    put(rightCol - text.length, row, text, color, { bold: true, glow: 8 });
  }

  function strike() {
    let c = 4 + Math.floor(Math.random() * (GW - 8));
    const pts = [];
    for (let r = 0; r < GH - 2; r++) {
      const d = Math.floor(Math.random() * 3) - 1;
      pts.push({ c, r, s: d < 0 ? '/' : d > 0 ? '\\' : '|' });
      c = Math.max(0, Math.min(GW - 1, c + d));
      if (r > 6 && Math.random() < 0.06) break;
    }
    bolt = { pts, t: 0 };
    nextBolt = 7 + Math.random() * 10;
  }

  function drawPrompt() {
    put(0, 0, 'doc@hillvalley', TERM.green, { bold: true });
    put(14, 0, ':', TERM.fg);
    put(15, 0, '~/outatime', TERM.blue, { bold: true });
    const cmd = mode === 'title' ? '' : `./outatime --level ${opts.startLevel}`;
    put(25, 0, '$ ' + cmd, TERM.fg);
    if (mode === 'title' && Math.floor(time * 2) % 2) put(27, 0, '█', TERM.fg);
    put(GW - 15, 0, '[ 1.21 GW ]', TERM.amber, { bold: true });
  }

  function drawStatusBar() {
    const row = GH - 1;
    const warn = danger > 0.5 && mode === 'playing';
    const bg = warn ? (Math.sin(time * 8) > 0 ? TERM.red : '#8a1010') : TERM.green;
    put(0, row, ' '.repeat(GW), '#000', { bg });
    put(1, row, '[jigowatt] 0:ssh  1:outatime*', '#000', { bold: true });
    const status = { paused: '-- PAUSED --', over: '-- TIME\'S UP --', dying: '-- TIME\'S UP --' }[mode] ?? (warn ? '!! TEMPORAL OVERLOAD !!' : '');
    if (status) put(Math.round(GW / 2 + 4 - status.length / 2), row, status, '#000', { bold: true });
    put(GW - 20, row, '10:04 PM 12-Nov-55', '#000');
  }

  function drawBoard() {
    const wall = danger > 0.01 && Math.sin(time * 10) > 0 ? TERM.red : TERM.dim;
    for (let r = 0; r < VIS; r++) {
      put(BOARD_COL, BOARD_ROW + r, '<!', wall, { bold: true });
      put(BOARD_COL + 22, BOARD_ROW + r, '!>', wall, { bold: true });
    }
    put(BOARD_COL, BOARD_ROW + VIS, '<!' + '='.repeat(20) + '!>', wall, { bold: true });
    put(BOARD_COL + 2, BOARD_ROW + VIS + 1, '\\/'.repeat(10), wall, { bold: true });
    if (!board) return;

    // Compose the well cell by cell, then draw it in one pass.
    const paused = mode === 'paused';
    const grid = [];
    for (let y = HIDDEN; y < ROWS; y++) {
      const row = [];
      const clearingRow = clearing && clearing.rows.includes(y);
      for (let x = 0; x < COLS; x++) {
        const t = board[y][x];
        let e = { s: ' .', c: TERM.faint, empty: true };
        if (t && !paused) e = dying && y >= dying.row ? { s: '##', c: TERM.dim } : { s: '[]', c: COLORS[t], bold: true };
        if (clearingRow && t) {
          const p = clearing.t / clearing.dur;
          if (p < 0.35) e = { s: '[]', c: Math.floor(p * 40) % 2 ? TERM.white : COLORS[t], bold: true, glow: 10 };
          else {
            const edge = ((p - 0.35) / 0.65) * 5.5, d = Math.abs(x - 4.5);
            e = d < edge ? { s: '  ', c: TERM.fg } : d < edge + 1 ? { s: '**', c: TERM.white, bold: true, glow: 12 } : { s: '==', c: TERM.white, bold: true };
          }
        }
        row.push(e);
      }
      grid.push(row);
    }
    const at = (x, y) => grid[y - HIDDEN]?.[x];

    for (const tr of trails) {
      for (let y = tr.y0; y < tr.y1; y++) {
        const e = at(tr.x, y);
        if (!e || !e.empty) continue;
        const k = (y - tr.y0) / Math.max(1, tr.y1 - tr.y0);
        Object.assign(e, { s: (y + Math.floor(time * 30)) % 2 ? '||' : '!!', c: k > 0.7 ? '#ffe08a' : '#ff8a1f', alpha: tr.life * (0.25 + 0.75 * k), glow: 6 });
      }
    }

    if (cur && !paused) {
      if (opts.ghost) {
        let gy = cur.y;
        while (fits(cur.type, cur.rot, cur.x, gy + 1)) gy++;
        for (const [cx, cy] of CELLS[cur.type][cur.rot]) {
          const e = at(cur.x + cx, gy + cy);
          if (e && e.empty) Object.assign(e, { s: '::', c: COLORS[cur.type], alpha: 0.55, bold: false });
        }
      }
      const fade = grounded() ? lockTimer / lockDelay() : 0;
      for (const [cx, cy] of CELLS[cur.type][cur.rot]) {
        const e = at(cur.x + cx, cur.y + cy);
        if (e) Object.assign(e, { s: '[]', c: COLORS[cur.type], alpha: 1 - fade * 0.55, bold: true, glow: 10, empty: false });
      }
    }

    for (let r = 0; r < VIS; r++) for (let x = 0; x < COLS; x++) {
      const e = grid[r][x];
      put(BOARD_COL + 2 + x * 2, BOARD_ROW + r, e.s, e.c, e);
    }
    for (const f of flashes) {
      if (f.y >= HIDDEN) put(BOARD_COL + 2 + f.x * 2, BOARD_ROW + f.y - HIDDEN, '[]', TERM.white, { alpha: f.life, bold: true, glow: 12 });
    }
    if (paused) put(CENTER_COL - 6, BOARD_ROW + 9, '  PAUSED  ', '#000', { bg: TERM.amber, bold: true });
  }

  function drawPanels(dt) {
    const L = LEFT_COL;
    const red = TERM.red, green = TERM.green, amber = TERM.amber;

    box(L, 2, 24, 6, 'HOLD');
    if (hold) piece(hold, L + 1, 22, 4, holdUsed ? 0.3 : 1);

    // Time circuits.
    const best = Math.max(highScores[0]?.score ?? 0, score ?? 0);
    put(L, 8, '┌' + '─'.repeat(22) + '┐', TERM.dim);
    put(L + 2, 8, ' SCORE ', red, { bold: true, bg: TERM.bg });
    put(L, 9, '│', TERM.dim); put(L + 23, 9, '│', TERM.dim);
    readout(L + 22, 9, String(Math.round(shownScore ?? 0)), red, 7);
    put(L, 10, '├' + '─'.repeat(22) + '┤', TERM.dim);
    put(L + 2, 10, ' BEST ', red, { bold: true, bg: TERM.bg });
    put(L, 11, '│', TERM.dim); put(L + 23, 11, '│', TERM.dim);
    readout(L + 22, 11, String(best), red, 7);
    put(L, 12, '├' + '─'.repeat(10) + '┬' + '─'.repeat(11) + '┤', TERM.dim);
    put(L + 2, 12, ' LEVEL ', green, { bold: true, bg: TERM.bg });
    put(L + 13, 12, ' LINES ', green, { bold: true, bg: TERM.bg });
    put(L, 13, '│', TERM.dim); put(L + 11, 13, '│', TERM.dim); put(L + 23, 13, '│', TERM.dim);
    readout(L + 10, 13, String(level ?? opts.startLevel).padStart(2, '0'), green, 2);
    readout(L + 22, 13, String(lines ?? 0).padStart(3, '0'), green, 3);
    put(L, 14, '├' + '─'.repeat(10) + '┴' + '─'.repeat(11) + '┤', TERM.dim);
    put(L + 2, 14, ' ELAPSED ', amber, { bold: true, bg: TERM.bg });
    put(L, 15, '│', TERM.dim); put(L + 23, 15, '│', TERM.dim);
    readout(L + 22, 15, fmtTime(elapsed ?? 0).padStart(5, '0'), amber, 5);
    put(L, 16, '└' + '─'.repeat(22) + '┘', TERM.dim);

    // Speedometer: hitting 88 MPH is a level up.
    box(L, 17, 24, 4, 'SPEED', amber);
    const target = levelFlash > 0.25 ? 88 : (((lines ?? 0) % 10) / 10) * 88;
    shownMph += (target - shownMph) * Math.min(1, dt * 5);
    const filled = Math.round((shownMph / 88) * 16);
    put(L + 2, 18, '[', TERM.dim, { bold: true });
    for (let i = 0; i < 16; i++) {
      const on = i < filled;
      put(L + 3 + i, 18, on ? '█' : '·', on ? (i >= 13 ? TERM.red : amber) : TERM.faint, { glow: on ? 6 : 0 });
    }
    put(L + 19, 18, ']', TERM.dim, { bold: true });
    const mph = String(Math.round(shownMph)).padStart(2, ' ');
    const hot = shownMph > 86;
    put(L + 20, 18, mph, hot ? TERM.red : amber, { bold: true, glow: hot ? 14 : 6 });
    put(L + 2, 19, hot ? 'MPH  >> TIME JUMP <<' : 'MPH', hot ? TERM.red : TERM.dim, { bold: hot });

    // NEXT queue.
    const R = RIGHT_COL;
    box(R, 2, 20, 18, 'NEXT');
    if (queue) {
      piece(queue[0], R + 1, 18, 4);
      for (let i = 1; i < 5; i++) piece(queue[i], R + 1, 18, 4 + i * 3, 1 - i * 0.15);
    }
    if (mode !== 'title' && b2b) put(R + 1, 20, '» B2B READY', '#ffd43b', { bold: true, glow: 6 });
    if (mode !== 'title' && combo > 0) put(R + 1, 21, `» COMBO x${combo}`, '#7cf0ff', { bold: true, glow: 6 });
  }

  function drawEffects() {
    for (const p of particles) {
      const col = Math.round(BOARD_COL + 2 + p.x * 2), row = Math.round(BOARD_ROW + p.y - HIDDEN - 0.5);
      if (row < 1 || row >= GH - 1) continue;
      put(col, row, p.life > 0.66 ? '*' : p.life > 0.33 ? '+' : '.', p.color, { alpha: Math.min(1, p.life * 1.3), bold: true, glow: 8 });
    }

    // Callouts type themselves out, terminal style, stacking upward.
    for (const p of popups) {
      const k = p.t / p.life;
      const shown = p.text.slice(0, Math.ceil(p.text.length * Math.min(1, k / 0.12)));
      const row = Math.round(BOARD_ROW + 8 + p.y + p.target);
      const alpha = k > 0.75 ? 1 - (k - 0.75) / 0.25 : 1;
      const col = Math.round(CENTER_COL - (p.text.length + 2) / 2);
      if (p.size >= 0.85) put(col, row, ` ${shown} `.padEnd(p.text.length + 2), '#000', { bg: p.color, alpha, bold: true });
      else put(col, row, ` ${shown} `, p.color, { bg: TERM.bg, alpha, bold: true, glow: 10 });
    }

    if (mode === 'countdown') {
      const n = 3 - Math.floor(countdown / 0.6);
      const k = (countdown % 0.6) / 0.6;
      const lines_ = bigText(n > 0 ? String(n) : 'GO!');
      const col = Math.round(CENTER_COL - lines_[0].length / 2);
      lines_.forEach((l, i) => put(col, BOARD_ROW + 7 + i, l, TERM.white, { alpha: 1 - Math.max(0, (k - 0.7) / 0.3), bold: true, glow: 14 }));
    }
  }

  function render(dt) {
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.textBaseline = 'middle'; g.textAlign = 'left';
    g.fillStyle = TERM.bg; g.fillRect(0, 0, W, H);
    if (danger > 0.01) { g.fillStyle = `rgba(255,30,40,${(danger * 0.06 * (1 + Math.sin(time * 7))).toFixed(3)})`; g.fillRect(0, 0, W, H); }

    const sx = shakeMag ? (Math.random() - 0.5) * shakeMag : 0, sy = shakeMag ? (Math.random() - 0.5) * shakeMag : 0;
    g.translate(sx, sy);
    drawPrompt();
    drawBoard();
    drawPanels(dt);
    drawEffects();
    drawStatusBar();
    g.setTransform(dpr, 0, 0, dpr, 0, 0);

    if ((mode === 'title' || mode === 'over') && (nextBolt -= dt) <= 0) { strike(); Sound.play('thunder'); }
    if (bolt) {
      bolt.t += dt;
      const a = Math.max(0, 1 - bolt.t / 0.5) * (0.6 + 0.4 * Math.sin(bolt.t * 90));
      for (const p of bolt.pts) put(p.c, p.r, p.s, '#dfe8ff', { alpha: a, bold: true, glow: 18 });
      g.fillStyle = `rgba(200,220,255,${(a * 0.1).toFixed(3)})`; g.fillRect(0, 0, W, H);
      if (bolt.t > 0.5) bolt = null;
    }

    // Time jump: white-out, then a signal glitch tearing the screen sideways.
    if (timeJump > 0.3) {
      g.setTransform(1, 0, 0, 1, 0, 0);
      for (let i = 0; i < 8; i++) {
        const y = Math.random() * canvas.height, h = (2 + Math.random() * 18) * dpr;
        g.drawImage(canvas, 0, y, canvas.width, h, (Math.random() - 0.5) * 60 * dpr * timeJump, y, canvas.width, h);
      }
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    if (timeJump > 0.75) { g.fillStyle = `rgba(240,255,240,${((timeJump - 0.75) * 3).toFixed(3)})`; g.fillRect(0, 0, W, H); }

    // CRT finish: scanlines and a soft vignette.
    g.fillStyle = scanlines; g.fillRect(0, 0, W, H);
    const v = g.createRadialGradient(W / 2, H / 2, Math.min(W, H) * 0.35, W / 2, H / 2, Math.max(W, H) * 0.75);
    v.addColorStop(0, 'rgba(0,0,0,0)'); v.addColorStop(1, 'rgba(0,0,0,0.55)');
    g.fillStyle = v; g.fillRect(0, 0, W, H);
  }

  /* ================= Update ================= */

  let lastCount = -1;
  function update(dt) {
    time += dt;
    shakeMag = Math.max(0, shakeMag - dt * 40);
    levelFlash = Math.max(0, levelFlash - dt * 1.6);
    if (shownScore !== undefined) shownScore += (score - shownScore) * Math.min(1, dt * 12);

    for (let i = particles.length - 1; i >= 0; i--) {
      const p = particles[i];
      p.vy += 38 * dt; p.x += p.vx * dt; p.y += p.vy * dt; p.vx *= 0.985;
      p.life -= p.decay * dt;
      if (p.life <= 0) particles.splice(i, 1);
    }
    for (let i = popups.length - 1; i >= 0; i--) {
      const p = popups[i];
      p.t += dt;
      if (p.t >= p.life) popups.splice(i, 1);
    }
    for (let i = trails.length - 1; i >= 0; i--) if ((trails[i].life -= dt * 2.6) <= 0) trails.splice(i, 1);
    timeJump = Math.max(0, timeJump - dt * 0.45);
    for (let i = flashes.length - 1; i >= 0; i--) if ((flashes[i].life -= dt * 6) <= 0) flashes.splice(i, 1);

    // DAS keeps charging during line clears so the next piece can shift instantly.
    if (input.dasDir && (mode === 'playing' || mode === 'clearing')) input.dasTimer += dt;

    if (mode === 'countdown') {
      countdown += dt;
      const n = Math.floor(countdown / 0.6);
      if (n !== lastCount && n <= 3) { lastCount = n; Sound.play('count', n === 3); }
      if (countdown >= 2.4) { mode = 'playing'; spawnNext(); }
      return;
    }

    if (mode === 'clearing') {
      elapsed += dt;
      clearing.t += dt;
      if (clearing.t >= clearing.dur) finishClear();
      return;
    }

    if (mode === 'dying') {
      dying.t += dt;
      while (dying.t > 0.045 && dying.row > HIDDEN - 1) { dying.t -= 0.045; dying.row--; }
      if (dying.row <= HIDDEN - 1 && dying.t > 0.6) finishGameOver();
      return;
    }

    if (mode !== 'playing' || !cur) return;
    elapsed += dt;

    if (input.dasDir && input.dasTimer >= opts.das / 1000) {
      input.arrTimer += dt;
      while (input.arrTimer >= ARR) { input.arrTimer -= ARR; if (!move(input.dasDir, true)) { input.arrTimer = 0; break; } }
    }

    const base = gravity();
    const softing = input.soft && cur.softOk;
    const interval = softing ? softInterval(base) : base;
    gravAcc += dt;
    if (softing) gravAcc = Math.min(gravAcc, interval); // no burst when soft drop starts mid-fall
    for (let steps = 0; gravAcc >= interval && steps < ROWS; steps++) {
      gravAcc -= interval;
      if (fits(cur.type, cur.rot, cur.x, cur.y + 1)) {
        cur.y++; lastRotate = false;
        if (softing) { score += 1; if (steps === 0) Sound.play('soft'); }
        afterMove();
      } else { gravAcc = 0; break; }
    }

    if (grounded()) {
      lockTimer += dt;
      const delay = lockDelay();
      if (lockTimer >= delay || (lockResets >= MAX_RESETS && lockTimer >= delay * 0.3)) lock();
    }

    // Danger level drives the red pulse and speeds the music up, like the original.
    let top = ROWS;
    for (let y = 0; y < ROWS && top === ROWS; y++) if (board[y].some(Boolean)) top = y;
    const target = top < HIDDEN + 5 ? 1 : 0;
    danger += (target - danger) * Math.min(1, dt * 4);
    Sound.setTempo(target ? 1.18 : 1);
  }

  /* ================= Input ================= */

  const BIND = {
    ArrowLeft: 'left', ArrowRight: 'right', ArrowDown: 'soft', ArrowUp: 'cw', KeyX: 'cw', KeyZ: 'ccw',
    ControlLeft: 'ccw', Space: 'hard', KeyC: 'hold', ShiftLeft: 'hold', ShiftRight: 'hold',
    Escape: 'pause', KeyP: 'pause', KeyM: 'mute',
    Numpad4: 'left', Numpad6: 'right', Numpad2: 'soft', Numpad8: 'cw', Numpad0: 'hold',
  };

  function gameKeyDown(action, repeat) {
    if (action === 'pause') { if (!repeat) pause(); return; }
    if (action === 'mute') { if (!repeat) toggleMute(); return; }
    if (repeat) return;
    if (action === 'left' || action === 'right') {
      const dir = action === 'left' ? -1 : 1;
      input[action] = true; input.dasDir = dir; input.dasTimer = 0; input.arrTimer = 0;
      if (mode === 'playing' && cur) move(dir);
      return;
    }
    if (action === 'soft') { input.soft = true; if (cur) cur.softOk = true; return; }
    if (mode !== 'playing' || !cur) return;
    if (action === 'cw') rotate(1);
    else if (action === 'ccw') rotate(-1);
    else if (action === 'hard') hardDrop();
    else if (action === 'hold') holdPiece();
  }

  function gameKeyUp(action) {
    if (action === 'left' || action === 'right') {
      input[action] = false;
      const other = action === 'left' ? 'right' : 'left';
      if (input.dasDir === (action === 'left' ? -1 : 1)) {
        input.dasDir = input[other] ? (other === 'left' ? -1 : 1) : 0;
        input.dasTimer = 0; input.arrTimer = 0;
      }
    } else if (action === 'soft') input.soft = false;
  }

  function releaseAll() { input.left = input.right = input.soft = false; input.dasDir = 0; }

  let muted = false;
  function toggleMute() {
    muted = !muted;
    Sound.setVolume('music', muted ? 0 : opts.musicVol / 10);
    popup(muted ? 'MUSIC OFF' : 'MUSIC ON', '#c9cff7', 0.45);
  }

  window.addEventListener('keydown', (e) => {
    if (e.metaKey) return; // leave ⌘W, ⌘Q etc. to the app
    Sound.init();
    if (!musicStarted && mode === 'title') startMusic();
    if (booting) { e.preventDefault(); skipBoot(); return; }
    if (e.target.tagName === 'INPUT') { if (e.key === 'Escape') e.target.blur(); return; }

    const action = BIND[e.code];
    const inGame = mode === 'playing' || mode === 'countdown' || mode === 'clearing';
    if (inGame && action) { e.preventDefault(); gameKeyDown(action, e.repeat); return; }
    if (mode === 'dying') { e.preventDefault(); return; }
    menuKey(e);
  });

  window.addEventListener('keyup', (e) => { const a = BIND[e.code]; if (a) gameKeyUp(a); });
  window.addEventListener('blur', () => { releaseAll(); if (mode === 'playing' || mode === 'clearing' || mode === 'countdown') pause(); });
  window.addEventListener('pointerdown', () => { Sound.init(); if (!musicStarted && mode === 'title') startMusic(); skipBoot(); });

  /* ================= Menus ================= */

  const $ = (s) => document.querySelector(s);
  const screens = { title: $('#screen-title'), options: $('#screen-options'), scores: $('#screen-scores'), pause: $('#screen-pause'), over: $('#screen-over') };
  let screen = null, screenStack = [];

  function showScreen(name, push) {
    if (push && screen) screenStack.push(screen); else screenStack = [];
    for (const k in screens) screens[k].classList.toggle('show', k === name);
    screen = name;
    if (name === 'options') renderOptions();
    if (name === 'scores') renderScores(screens.scores.querySelector('tbody'));
    requestAnimationFrame(() => focusables()[0]?.focus());
  }
  function hideScreens() { for (const k in screens) screens[k].classList.remove('show'); screen = null; screenStack = []; }
  function back() { const prev = screenStack.pop(); if (prev) { const stack = screenStack; showScreen(prev); screenStack = stack; } }
  function showControls(on) { $('#controls').classList.toggle('show', on); }

  function focusables() {
    if (!screen) return [];
    return [...screens[screen].querySelectorAll('.opt, .btn, input')].filter((el) => el.offsetParent !== null);
  }

  function menuKey(e) {
    if (!screen) return;
    const items = focusables();
    const i = items.indexOf(document.activeElement);
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      const n = items.length, next = i < 0 ? 0 : (i + (e.key === 'ArrowDown' ? 1 : -1) + n) % n;
      items[next]?.focus(); Sound.play('menu');
    } else if ((e.key === 'ArrowLeft' || e.key === 'ArrowRight') && document.activeElement?.classList.contains('opt')) {
      e.preventDefault(); changeOpt(document.activeElement.dataset.opt, e.key === 'ArrowLeft' ? -1 : 1);
    } else if (e.key === 'Enter' || e.key === ' ') {
      const el = document.activeElement;
      if (el?.classList.contains('opt')) { e.preventDefault(); changeOpt(el.dataset.opt, 1); }
      else if (!el || !items.includes(el)) { e.preventDefault(); items[0]?.click(); }
    } else if (e.key === 'Escape' || e.code === 'KeyP') {
      e.preventDefault();
      if (screenStack.length) { Sound.play('menu'); back(); }
      else if (screen === 'pause') resume();
    }
  }

  document.addEventListener('click', (e) => {
    const btn = e.target.closest('[data-action]');
    if (btn) { Sound.init(); Sound.play('select'); doAction(btn.dataset.action); return; }
    const opt = e.target.closest('.opt');
    if (opt) changeOpt(opt.dataset.opt, 1);
  });
  document.addEventListener('mouseover', (e) => { const el = e.target.closest('.btn, .opt'); if (el && el !== document.activeElement) { el.focus(); } });

  function doAction(a) {
    if (a === 'start' || a === 'restart') newGame();
    else if (a === 'options') showScreen('options', true);
    else if (a === 'scores') showScreen('scores', true);
    else if (a === 'back') back();
    else if (a === 'resume') resume();
    else if (a === 'quit') toTitle();
  }

  function pause() {
    if (mode === 'paused') return resume();
    pausedFrom = mode; mode = 'paused';
    releaseAll();
    Sound.pauseSong(); Sound.play('pause');
    showControls(false);
    showScreen('pause');
  }

  function resume() {
    if (mode !== 'paused') return;
    hideScreens();
    showControls(true);
    mode = pausedFrom;
    Sound.resumeSong(); Sound.play('pause');
  }

  function toTitle() {
    mode = 'title';
    board = emptyBoard(); cur = null; queue = null; hold = null;
    score = undefined; shownScore = undefined; lines = undefined; level = undefined;
    combo = -1; b2b = false; danger = 0;
    showControls(false);
    showScreen('title');
    Sound.setTempo(1);
    startMusic();
  }

  let musicStarted = false;
  function startMusic() {
    musicStarted = true;
    Sound.setVolume('music', muted ? 0 : opts.musicVol / 10);
    Sound.setVolume('sfx', opts.sfxVol / 10);
    if (opts.music) Sound.playSong(SONG); else Sound.stopSong();
  }

  /* ---------- Options ---------- */

  const OPTS = {
    startLevel: { range: [1, 15], fmt: (v) => String(v) },
    music: { bool: true },
    musicVol: { range: [0, 10], fmt: (v) => '▮'.repeat(v) + '▯'.repeat(10 - v) },
    sfxVol: { range: [0, 10], fmt: (v) => '▮'.repeat(v) + '▯'.repeat(10 - v) },
    ghost: { bool: true },
    shake: { bool: true },
    das: { list: [100, 133, 167, 200, 250], fmt: (v) => `${v} ms` },
  };

  function renderOptions() {
    for (const el of screens.options.querySelectorAll('.opt')) {
      const k = el.dataset.opt, spec = OPTS[k], v = opts[k];
      el.querySelector('b').textContent = spec.bool ? (v ? 'On' : 'Off') : spec.fmt(v);
    }
  }

  function changeOpt(k, dir) {
    const spec = OPTS[k];
    if (spec.bool) opts[k] = !opts[k];
    else if (spec.range) opts[k] = Math.max(spec.range[0], Math.min(spec.range[1], opts[k] + dir));
    else { const i = spec.list.indexOf(opts[k]); opts[k] = spec.list[(i + dir + spec.list.length) % spec.list.length]; }
    store.set('options', opts);
    renderOptions();
    Sound.setVolume('music', muted ? 0 : opts.musicVol / 10);
    Sound.setVolume('sfx', opts.sfxVol / 10);
    if (k === 'music') { startMusic(); if (mode === 'paused') Sound.pauseSong(); }
    Sound.play(k === 'sfxVol' ? 'lock' : 'menu');
  }

  /* ---------- High scores ---------- */

  const fmtTime = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  let lastEntry = null;

  function renderScores(tbody) {
    if (!highScores.length) { tbody.innerHTML = '<tr class="empty"><td colspan="4">No scores yet — go set one!</td></tr>'; return; }
    tbody.innerHTML = highScores.map((s, i) =>
      `<tr class="${s === lastEntry ? 'me' : ''}"><td>${i + 1}</td><td>${esc(s.name)}</td><td class="lv">L${s.level} · ${s.lines}</td><td class="num">${s.score.toLocaleString()}</td></tr>`).join('');
  }

  function qualifies() { return score > 0 && (highScores.length < 10 || score > highScores[highScores.length - 1].score); }

  function showGameOver() {
    $('#f-score').textContent = score.toLocaleString();
    $('#f-lines').textContent = lines;
    $('#f-level').textContent = level;
    $('#f-time').textContent = fmtTime(elapsed);
    lastEntry = null;
    const form = $('#name-entry');
    const tbody = screens.over.querySelector('tbody');
    form.classList.toggle('show', qualifies());
    tbody.parentElement.style.display = qualifies() ? 'none' : '';
    renderScores(tbody);
    showScreen('over');
    if (qualifies()) {
      const input_ = $('#name');
      input_.value = lastName;
      setTimeout(() => { input_.focus(); input_.select(); }, 60);
    }
  }

  $('#name-entry').addEventListener('submit', (e) => {
    e.preventDefault();
    const name = $('#name').value.trim() || 'Player';
    lastName = name; store.set('name', name);
    lastEntry = { name, score, lines, level, date: Date.now() };
    highScores.push(lastEntry);
    highScores.sort((a, b) => b.score - a.score);
    highScores = highScores.slice(0, 10);
    store.set('scores', highScores);
    $('#name-entry').classList.remove('show');
    const tbody = screens.over.querySelector('tbody');
    tbody.parentElement.style.display = '';
    renderScores(tbody);
    Sound.play('select');
    requestAnimationFrame(() => focusables()[0]?.focus());
  });

  /* ---------- Title boot sequence ---------- */

  let booting = false, skipBoot = () => {};
  function boot() {
    $('#logo').textContent = bigText('OUTATIME').join('\n');
    const el = $('#boot'), title = screens.title;
    const script = [
      ['<span class="p">$</span> ', 'ssh doc@hillvalley', true],
      ['', 'Last login: Sat Oct 26 01:21:00 1985 from twin-pines-mall', false],
      ['<span class="p">doc@hillvalley</span>:<span class="d">~</span>$ ', './outatime', true],
    ];
    const cursor = '<span class="c"> </span>';
    let line = 0, chr = 0, done = '', timer;
    booting = true;
    title.classList.add('booting');
    skipBoot = () => {
      if (!booting) return;
      clearTimeout(timer);
      booting = false;
      el.innerHTML = script.map(([p, t]) => p + esc(t)).join('\n') + cursor;
      title.classList.remove('booting');
      focusables()[0]?.focus();
    };
    const step = () => {
      if (line >= script.length) { timer = setTimeout(skipBoot, 350); return; }
      const [p, t, typed] = script[line];
      chr = typed ? chr + 1 : t.length;
      el.innerHTML = done + p + esc(t.slice(0, chr)) + cursor;
      if (chr >= t.length) { done += p + esc(t) + '\n'; line++; chr = 0; timer = setTimeout(step, typed ? 380 : 260); }
      else timer = setTimeout(step, 35 + Math.random() * 50);
    };
    timer = setTimeout(step, 450);
  }

  /* ================= Main loop ================= */

  let last = performance.now();
  function frame(now) {
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    update(dt);
    render(dt);
    requestAnimationFrame(frame);
  }

  window.addEventListener('resize', resize);
  resize();
  board = emptyBoard();
  showScreen('title');
  boot();
  requestAnimationFrame(frame);

  // Debug hook for automated checks.
  window.__game = { get mode() { return mode; }, get score() { return score; }, get board() { return board; }, get cur() { return cur; } };
})();
