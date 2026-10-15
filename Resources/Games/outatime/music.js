'use strict';

/*
 * "88 Miles Per Hour" — an original synthwave track in A minor.
 * Notes are MIDI-style: "NOTE:beats", "r" for rest, "+" for chords.
 */
const SONG = (() => {
  const rep = (s, n) => Array(n).fill(s).join(' ');

  // Chord voicings: [bass root, pad voicing, arpeggio tones].
  const CH = {
    Am: ['A1', 'A3+C4+E4', ['A4', 'C5', 'E5', 'A5']],
    F:  ['F1', 'F3+A3+C4', ['F4', 'A4', 'C5', 'F5']],
    C:  ['C2', 'G3+C4+E4', ['G4', 'C5', 'E5', 'G5']],
    G:  ['G1', 'G3+B3+D4', ['G4', 'B4', 'D5', 'G5']],
    Em: ['E1', 'G3+B3+E4', ['E4', 'G4', 'B4', 'E5']],
    E:  ['E1', 'G#3+B3+E4', ['E4', 'G#4', 'B4', 'E5']],
  };
  const octave = (n) => n.replace(/\d$/, (d) => +d + 1);

  // Driving eighth-note bass that jumps up an octave on the offbeats.
  const bass = (chords) => chords.map((c) => {
    const r = CH[c][0], hi = octave(r);
    return `${r}:.5 ${r}:.5 ${hi}:.5 ${r}:.5 ${r}:.5 ${r}:.5 ${hi}:.5 ${r}:.5`;
  }).join(' ');
  const pad = (chords) => chords.map((c) => `${CH[c][1]}:4`).join(' ');
  // 16th-note arpeggio: up, up, up, down shape.
  const arp = (chords) => chords.map((c) => {
    const [a, b, d, e] = CH[c][2];
    return rep(`${a}:.25 ${b}:.25 ${d}:.25 ${e}:.25 ${d}:.25 ${b}:.25 ${d}:.25 ${b}:.25`, 2);
  }).join(' ');

  // Four-on-the-floor kick, gated snare on 2 and 4, 16th hats, tom fill on bar 8.
  const groove = 'k+h:.25 h:.25 h:.25 h:.25 k+s+h:.25 h:.25 h:.25 h:.25 k+h:.25 h:.25 h:.25 h:.25 k+s+h:.25 h:.25 h:.25 h:.25';
  const fill = 'k+h:.25 h:.25 h:.25 h:.25 k+s+h:.25 h:.25 h:.25 h:.25 th:.25 th:.25 tm:.25 tm:.25 tl:.25 tl:.25 s:.25 s:.25';
  const introBeat = 'k:.5 h:.5 k:.5 h:.5 k:.5 h:.5 k:.5 h:.5';

  const INTRO = ['Am', 'F', 'C', 'G'];
  const VERSE = ['Am', 'F', 'C', 'G', 'Am', 'F', 'G', 'G'];
  const BRIDGE = ['F', 'G', 'Em', 'Am', 'F', 'G', 'E', 'E'];

  const verseLead = `
    A4:.5 C5:.5 E5:1 D5:.5 E5:1 C5:.5
    C5:1.5 A4:.5 F5:1 E5:1
    G5:1.5 E5:.5 C5:1 D5:.5 E5:.5
    D5:2 B4:1 G4:1
    A4:.5 C5:.5 E5:1 D5:.5 E5:1 A5:.5
    A5:1.5 G5:.5 F5:1 E5:1
    D5:1 E5:.5 D5:.5 B4:1 G4:1
    B4:.5 C5:.5 D5:3`;
  const bridgeLead = `
    C6:1 A5:1 F5:1 A5:1
    B5:1.5 G5:.5 D5:2
    E5:.5 G5:.5 B5:1 A5:.5 G5:.5 E5:1
    A5:3 r:1
    C6:1 A5:1 F5:1 C6:1
    D6:1.5 B5:.5 G5:2
    G#5:1 B5:1 E6:1 D6:.5 B5:.5
    G#5:2 E5:1 r:1`;

  const form = [INTRO, VERSE, BRIDGE, VERSE];
  const all = form.flat();

  return {
    title: '88 Miles Per Hour',
    bpm: 124,
    tracks: [
      { inst: 'lead', notes: ['r:16', verseLead, bridgeLead, verseLead].join(' ') },
      { inst: 'arp', notes: arp(all) },
      { inst: 'pad', notes: pad(all) },
      { inst: 'bass', notes: bass(all) },
      { inst: 'drums', notes: [rep(introBeat, 3), fill, rep(groove, 7), fill, rep(groove, 7), fill, rep(groove, 7), fill].join(' ') },
    ],
  };
})();
