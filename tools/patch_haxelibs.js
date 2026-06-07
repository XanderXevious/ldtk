const { execSync } = require('child_process');
const path = require('path');
const fs = require('fs');

// Get the haxelib path (first line of output is the classpath)
const haxelibPath = execSync('haxelib path ldtk-haxe-api')
    .toString()
    .split('\n')[0]
    .trim();

const dest = path.join(haxelibPath, 'ldtk', 'Json.hx');
const src = path.join(__dirname, '..', 'local_overrides', 'Json.hx');

console.log('Patching: ' + dest);
fs.copyFileSync(src, dest);
console.log('Done.');