const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

// Compile the actual production codecs and disk actor, not a JavaScript imitation of them.
if (process.platform !== 'darwin') {
    console.error('This disk/runtime check needs macOS with Xcode Command Line Tools. It is not a Windows source check.');
    process.exit(1);
}
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, 'AURU MUSIC', 'Services', name), 'utf8');
const between = (source, start, end) => {
    const from = source.indexOf(start);
    const to = source.indexOf(end, from);
    assert.ok(from >= 0 && to > from, `Missing source markers ${start} … ${end}`);
    return source.slice(from, to);
};
const service = read('CandyPlazaService.swift');
const transfer = read('CandyReliableTransfer.swift');
const parts = [
    between(service, 'struct CandyPlazaFile:', 'struct CandyPlazaHistory:'),
    between(service, 'struct CandyEnvelope:', 'private struct CandyGatewayMessage'),
    between(service, 'enum CandyCodec', '// MARK: - Service'),
    between(transfer, 'let candyBlockSize', 'struct CandySignal:'),
    between(transfer, 'enum CandyTransferFailure:', 'private actor CandyTransferSource'),
];

async function main() {
    const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'candy-disk-test-'));
    try {
        const swift = path.join(folder, 'Production.swift');
        fs.writeFileSync(swift, `import Foundation\nimport CryptoKit\nimport Security\n${parts.join('\n')}\n`);
        const output = path.join(folder, 'verify-disk');
        const compile = spawnSync('xcrun', ['swiftc', '-parse-as-library', swift, path.join(__dirname, 'verify-candy-disk.swift'), '-o', output], { stdio: 'inherit' });
        if (compile.error) throw compile.error;
        if (compile.status !== 0) { process.exitCode = compile.status || 1; return; }
        const run = spawnSync(output, [], { encoding: 'utf8' });
        if (run.error) throw run.error;
        process.stderr.write(run.stderr);
        const lines = run.stdout.split('\n');
        lines.filter(line => !line.startsWith('ENVELOPE:')).forEach(line => line && console.log(line));
        if (run.status !== 0) { process.exitCode = run.status === null ? 1 : run.status; return; }
        // Cross-check the Swift-signed envelope with the JS verifier (same rules as the Go node).
        const envelopeLine = lines.find(line => line.startsWith('ENVELOPE:'));
        assert.ok(envelopeLine, 'Swift did not print its envelope');
        const { verifyEnvelope } = await import(pathToFileURL(path.join(root, 'web', 'src', 'lib', 'plaza.ts')).href);
        const body = await verifyEnvelope(JSON.parse(envelopeLine.slice('ENVELOPE:'.length)));
        assert.equal(body.peerId, '12D3KooWA4Xop1JaT3MHxwYMkCepYsv4iPVopMXwCz5iHYdBfeSB');
        console.log('PASS: Swift envelope verified by the JS/libp2p implementation (requires `npm install` in web/).');
    } finally {
        fs.rmSync(folder, { recursive: true, force: true });
    }
}

main().catch(error => {
    console.error(`FAIL: ${error.message}`);
    process.exitCode = 1;
});
