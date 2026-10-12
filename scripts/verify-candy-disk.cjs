const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

// Compile the actual portable disk actor, not a JavaScript imitation of it.
if (process.platform !== 'darwin') {
    console.error('This disk/runtime check needs macOS with Xcode Command Line Tools. It is not a Windows source check.');
    process.exit(1);
}
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Services', 'CandyReliableTransfer.swift'), 'utf8');
const service = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Services', 'CandyPlazaService.swift'), 'utf8');
const model = service.slice(service.indexOf('struct CandyPlazaFile:'), service.indexOf('struct CandyPlazaHistory:'));
const wire = source.slice(source.indexOf('struct CandyTransferGrant:'), source.indexOf('private struct CandyTransferSignal:'));
const disk = source.slice(source.indexOf('enum CandyTransferFailure:'), source.indexOf('@MainActor\nfinal class CandyReliableTransfer'))
    .replace('private actor CandyUploadBudget', 'actor CandyUploadBudget');
assert.ok(model.includes('sha256') && disk.includes('actor CandyTransferDisk'));
const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'candy-disk-test-'));
try {
    const swift = path.join(folder, 'Disk.swift');
    fs.writeFileSync(swift, `import Foundation\nimport CryptoKit\n${model}\n${wire}\n${disk}\n`);
    const output = path.join(folder, 'verify-disk');
    const compile = spawnSync('xcrun', ['swiftc', '-parse-as-library', swift, path.join(__dirname, 'verify-candy-disk.swift'), '-o', output], { stdio: 'inherit' });
    if (compile.error) throw compile.error;
    if (compile.status !== 0) process.exitCode = compile.status || 1;
    else {
        const run = spawnSync(output, [], { stdio: 'inherit' });
        process.exitCode = run.status === null ? 1 : run.status;
        if (run.error) throw run.error;
    }
} finally {
    for (const name of fs.readdirSync(folder)) fs.unlinkSync(path.join(folder, name));
    fs.rmdirSync(folder);
}
