// Fake debugserver: thread 1 hits brk #0xf00d asking for a region (x16=1, x0=0, x1=0x400000),
// then a SIGSEGV (must be passed back), then brk #0xf00d with x16=0 (detach).
// Run: node .ci/jit-script/test.js  (extracts the script from vita3k/ios/ui/JITEnabler.swift)
const fs = require('fs');
const path = require('path');
const swift = fs.readFileSync(path.join(__dirname, '../../vita3k/ios/ui/JITEnabler.swift'), 'utf8');
const start = swift.indexOf('static let jitScript = #"""') + 'static let jitScript = #"""'.length;
const script = swift.slice(start, swift.indexOf('"""#', start)).split('\n').map(l => l.replace(/^    /, '')).join('\n');
const le = v => { let h = ''; for (let i = 0; i < 8; i++) { h += Number(v & 0xffn).toString(16).padStart(2, '0'); v >>= 8n; } return h; };
const brk = 0xD43E01A0; const brkHex = [0,1,2,3].map(i => ((brk >>> (8*i)) & 0xff).toString(16).padStart(2,'0')).join('');
let pc = 0x100004000n;
const stops = [
  () => `T05thread:1a;name:main;threads:1a;00:${le(0n)};01:${le(0x400000n)};10:${le(1n)};20:${le(pc)};metype:6;`,
  () => `T0bthread:1a;00:${le(0n)};20:${le(0x200000n)};`,
  () => `T05thread:1a;00:${le(0n)};01:${le(0n)};10:${le(0n)};20:${le(pc)};`,
];
let stop = 0; const log_ = [];
global.get_pid = () => 1234;
global.log = m => log_.push('LOG ' + m);
global.prepare_memory_region = (a, s) => log_.push(`PREPARE 0x${a.toString(16)} size 0x${s.toString(16)}`);
global.send_command = c => {
  log_.push('> ' + c);
  if (c === 'c' || c.startsWith('C')) return stop < stops.length ? stops[stop++]() : 'W00';
  if (c.startsWith('m')) return brkHex;
  if (c.startsWith('_M')) return '2a0000000';
  return 'OK';
};
eval(script);
console.log(log_.join('\n'));
const expect = ['PREPARE 0x2a0000000 size 0x400000', '> P0=000000a002000000;thread:1a;', '> C0b', '> D'];
const missing = expect.filter(e => !log_.includes(e));
if (missing.length) { console.error('JIT script test FAILED, missing: ' + missing.join(' | ')); process.exit(1); }
console.log('JIT script test passed');
