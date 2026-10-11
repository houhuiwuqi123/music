const { spawnSync } = require('node:child_process');
const path = require('node:path');

if (process.platform !== 'darwin') {
    console.error('An iOS build requires macOS and Xcode; this command cannot validate Swift on Windows.');
    process.exit(1);
}
const root = path.resolve(__dirname, '..');
const build = spawnSync('xcodebuild', [
    '-project', path.join(root, 'MusicPlayer.xcodeproj'),
    '-scheme', 'AURU MUSIC',
    '-configuration', 'Debug',
    '-sdk', 'iphonesimulator',
    '-destination', 'generic/platform=iOS Simulator',
    'CODE_SIGNING_ALLOWED=NO',
    'build'
], { cwd: root, stdio: 'inherit' });
if (build.error) {
    console.error(build.error.message);
    process.exitCode = 1;
} else process.exitCode = build.status === null ? 1 : build.status;
