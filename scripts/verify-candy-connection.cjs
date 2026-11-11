const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const https = require('node:https');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const service = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Services', 'CandyPlazaService.swift'), 'utf8');
const transfer = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Services', 'CandyReliableTransfer.swift'), 'utf8');
const view = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Views', 'CandyPlazaView.swift'), 'utf8');
const plist = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Info.plist'), 'utf8');

function verifyViewScopes(source) {
    // This limited structural check is not a Swift parser or type-checker.
    const code = source.replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*|"(?:\\.|[^"\\])*"/g, '');
    const required = new Set(['CandyPlazaView', 'CandyFileStar', 'CandyProfileView']);
    let depth = 0;
    for (const match of code.matchAll(/\bstruct\s+(\w+)|[{}]/g)) {
        if (match[1]) {
            if (required.has(match[1])) {
                assert.equal(depth, 0, `${match[1]} must be declared at file scope`);
                required.delete(match[1]);
            }
        } else if (match[0] === '{') {
            depth++;
        } else {
            depth--;
            assert.ok(depth >= 0, 'Unexpected closing brace in plaza view');
        }
    }
    assert.equal(depth, 0, 'Unclosed scope in plaza view');
    assert.equal(required.size, 0, 'Missing plaza view declarations');
}

function verifyStarMotion() {
    const start = view.match(/let startX = ([\d.]+) \+ Double\(seed % 100\) \/ 100 \* ([\d.]+)/);
    const end = view.match(/let endX = ([\d.]+) \+ Double\(\(seed >> 8\) % 100\) \/ 100 \* ([\d.]+)/);
    const vertical = view.match(/let y = ([\d.]+) - progress \* ([\d.]+)/);
    const scale = view.match(/let scale = ([\d.]+) - progress \* ([\d.]+)/);
    assert.ok(start && end && vertical && scale, 'Missing meteor trajectory coefficients');
    assert.ok(view.includes('let x = startX + (endX - startX) * progress'));
    assert.ok(view.includes('let progress = time - Double(cycle)'));
    assert.ok(view.includes('let time = max(0, date.timeIntervalSince(flightStartedAt) - Double(hash % 1000) / 1000 * 3) / 14'));
    assert.ok(view.includes('flightStartedAt = flightStartedAt.addingTimeInterval(Date().timeIntervalSince(frozenDate))'));
    for (let a = 0; a < 100; a++) {
        for (let b = 0; b < 100; b++) {
            const startX = Number(start[1]) + a / 100 * Number(start[2]);
            const endX = Number(end[1]) + b / 100 * Number(end[2]);
            assert.ok(startX >= 0.80 && startX <= 1, 'Must emerge at bottom-right');
            assert.ok(endX >= 0 && endX <= 0.25, 'Must finish at top-left');
            let previous = { x: Infinity, y: Infinity, size: Infinity };
            for (let step = 0; step <= 20; step++) {
                const progress = step / 20;
                const x = startX + (endX - startX) * progress;
                const y = Number(vertical[1]) - progress * Number(vertical[2]);
                const size = Number(scale[1]) - progress * Number(scale[2]);
                assert.ok(x < previous.x && y < previous.y && size < previous.size);
                assert.ok(size > 0);
                if (step === 0) assert.ok(y >= 0.80 && y <= 1);
                if (step === 20) assert.ok(y >= 0 && y <= 0.25);
                previous = { x, y, size };
            }
        }
    }
    for (const name of ['PlazaEmpty', 'PlazaOnline']) {
        const folder = path.join(root, 'AURU MUSIC', 'Assets.xcassets', `${name}.imageset`);
        const asset = JSON.parse(fs.readFileSync(path.join(folder, 'Contents.json'), 'utf8'));
        assert.equal(asset.images[0].idiom, 'universal');
        const image = fs.readFileSync(path.join(folder, asset.images[0].filename));
        assert.equal(image.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
        assert.equal(image.readUInt32BE(16), 768);
        assert.equal(image.readUInt32BE(20), 768);
    }
    assert.ok(view.includes('Image(plaza.listeners.contains { !$0.isOffline } ? "PlazaOnline" : "PlazaEmpty")'));
    assert.ok(view.includes('alignment: .bottomTrailing'));
    assert.ok(view.includes('.offset(x: 23, y: 23)'));
}

function verifySource() {
    verifyViewScopes(view);
    assert.throws(() => verifyViewScopes(view.replace('private struct CandyProfileView', '{ private struct CandyProfileView')));
    verifyStarMotion();
    assert.ok(!view.includes('plaza.connectionError') && !view.includes('connectionTimeout'));
    assert.ok(!plist.includes('NSExceptionAllowsInsecureHTTPLoads'));
    const rootView = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Views', 'RootView.swift'), 'utf8');
    assert.ok(rootView.includes('Publishers.CombineLatest(player.$currentTrack, player.$isPlaying)'));
    assert.ok(rootView.includes('plaza.start()'));
    const settingsView = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Views', 'SettingsView.swift'), 'utf8');
    assert.ok(settingsView.includes('plaza.setSharesListening($0)') && view.includes('ForEach(visibleListeners)'));
    assert.ok(view.includes('listener.region ?? "地区未知"') && view.includes('.id(listener.id)'));
    assert.ok(view.includes('action: { selectedFile = listener.file }'));
    assert.ok(view.includes('paused: listener.isOffline') && view.includes('.truncationMode(.tail)'));
    assert.ok(view.includes('Button("下载")') && view.includes('Button("取消", role: .cancel)'));
    assert.ok(view.includes('plaza.cancelDownload(download.id)') && view.includes('plaza.retryDownload(download.file)'));

    // DHT protocol: the Go node, the Vue client and the iOS app must agree byte-for-byte.
    const read = (...parts) => fs.readFileSync(path.join(root, ...parts), 'utf8');
    const go = read('backend', 'internal', 'node', 'protocol.go') + read('backend', 'internal', 'node', 'plaza.go') + read('backend', 'internal', 'node', 'session.go');
    const web = read('web', 'src', 'lib', 'network.ts') + read('web', 'src', 'lib', 'transfer.ts') + read('web', 'src', 'lib', 'content.ts') + read('web', 'src', 'lib', 'plaza.ts');
    for (const value of ['/auru/kad/1.0.0', '/auru/signal/1.0.0', '/auru/resolve/1.0.0', '/auru/plaza/1.0.0', 'auru/plaza/1']) {
        assert.ok(go.includes(`"${value}"`) || go.includes(`${value.split('/').pop()}`), `Go missing ${value}`);
        assert.ok(web.includes(`'${value}'`), `web missing ${value}`);
    }
    for (const prefix of ['auru-plaza:', 'auru-node-auth:']) {
        assert.ok(go.includes(`"${prefix}"`), `Go missing ${prefix}`);
        assert.ok(service.includes(`"${prefix}"`), `Swift missing ${prefix}`);
    }
    assert.ok(web.includes("SIGNATURE_PREFIX = 'auru-plaza:'"));
    assert.ok(transfer.includes('let candyChannelLabel = "auru-file/1"') && web.includes("CHANNEL_LABEL = 'auru-file/1'"));
    assert.ok(transfer.includes('let candyBlockSize = 1_048_576') && web.includes('BLOCK_SIZE = 1024 * 1024'));
    assert.ok(transfer.includes('let candyChunkSize = 65_536') && web.includes('CHUNK_SIZE = 64 * 1024'));
    for (const field of ['"get"', '"meta"', '"end"', '"done"', '"error"']) {
        assert.ok(transfer.includes(`t: ${field}`) || transfer.includes(`.t == ${field}`), `Swift wire message ${field}`);
    }
    assert.ok(service.includes('Data([0x08, 0x01, 0x12, 0x20])') && service.includes('Data([0x00, 0x24])'), 'libp2p Ed25519 peer ID encoding');
    assert.ok(service.includes('[0x01, 0x55, 0x12, 0x20]'), 'CIDv1 raw sha2-256 prefix');
    assert.ok(service.includes('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly') && service.includes('Curve25519.Signing.PrivateKey'));
    assert.ok(service.includes('NWPathMonitor()') && service.includes('transfers.networkChanged()'), 'reconnect on network switch');
    assert.ok(service.includes('willEnterForegroundNotification'));
    assert.ok(service.includes('https://music.webtrc.eu.cc/api/bootstrap') && service.includes('wss://music.webtrc.eu.cc/ws'));
    assert.ok(transfer.includes('func rewind(to target: Int64)') && transfer.includes('digest == blocks[blockIndex]'));
    assert.ok(transfer.includes('digest() == file.sha256') && transfer.includes('try handle?.synchronize()'));
    assert.doesNotMatch(service + transfer, /file-v2|transfer-request|share-retire|lease-refresh|gateway\/v2/, 'old hub protocol must be gone');
    const project = fs.readFileSync(path.join(root, 'MusicPlayer.xcodeproj', 'project.pbxproj'), 'utf8');
    assert.equal((project.match(/CandyReliableTransfer.swift in Sources/g) || []).length, 2);
    assert.equal((project.match(/CandyPlazaService.swift in Sources/g) || []).length, 2);
    assert.ok(service.includes('now - $0.value >= 60'));
    console.log('PASS: client source/config regression checks (not a Swift build).');
}

function publicAddresses() {
    return new Promise((resolve, reject) => {
        const request = https.get('https://dns.google/resolve?name=music.webtrc.eu.cc&type=A', response => {
            let body = '';
            response.setEncoding('utf8');
            response.on('data', chunk => { body += chunk; });
            response.on('error', reject);
            response.on('end', () => {
                try {
                    assert.equal(response.statusCode, 200);
                    const result = JSON.parse(body);
                    assert.equal(result.Status, 0);
                    const addresses = (result.Answer || []).filter(answer => answer.type === 1).map(answer => answer.data);
                    assert.ok(addresses.length > 0, 'No public IPv4 addresses returned');
                    resolve(addresses);
                } catch (error) {
                    reject(error);
                }
            });
        });
        request.setTimeout(15000, () => request.destroy(new Error('Public DNS lookup timed out')));
        request.on('error', reject);
    });
}

function verifyPublicSnapshot(address) {
    return new Promise((resolve, reject) => {
        const key = crypto.randomBytes(16).toString('base64');
        const expectedAccept = crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
        let socket;
        let settled = false;
        const finish = error => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            socket?.destroy();
            request.destroy();
            if (error) reject(error);
            else resolve();
        };
        const request = https.request({
            hostname: address,
            servername: 'music.webtrc.eu.cc',
            port: 443,
            path: '/ws',
            headers: {
                Host: 'music.webtrc.eu.cc',
                Connection: 'Upgrade',
                Upgrade: 'websocket',
                'Sec-WebSocket-Version': '13',
                'Sec-WebSocket-Key': key
            }
        });
        const timer = setTimeout(() => finish(new Error('No gateway challenge within 30 seconds')), 30000);
        request.on('error', finish);
        request.on('response', response => {
            response.resume();
            finish(new Error(`Public endpoint returned HTTP ${response.statusCode}, expected WebSocket HTTP 101`));
        });
        request.on('upgrade', (response, upgradedSocket, head) => {
            socket = upgradedSocket;
            try {
                assert.equal(response.statusCode, 101);
                assert.equal(response.headers['sec-websocket-accept'], expectedAccept);
            } catch (error) {
                finish(error);
                return;
            }
            let data = Buffer.alloc(0);
            const receive = chunk => {
                try {
                    data = Buffer.concat([data, chunk]);
                    if (data.length < 2) return;
                    assert.equal(data[0], 0x81, 'Expected an unfragmented JSON text frame');
                    assert.equal(data[1] & 0x80, 0, 'Server frame must not be masked');
                    let length = data[1] & 0x7f;
                    let offset = 2;
                    if (length === 126) {
                        if (data.length < 4) return;
                        length = data.readUInt16BE(2);
                        offset = 4;
                    } else if (length === 127) {
                        if (data.length < 10) return;
                        const size = data.readBigUInt64BE(2);
                        assert.ok(size <= 1048576n, 'Frame exceeds test limit');
                        length = Number(size);
                        offset = 10;
                    }
                    if (data.length < offset + length) return;
                    const message = JSON.parse(data.subarray(offset, offset + length).toString('utf8'));
                    assert.equal(message.type, 'challenge', 'Gateway must open with an Ed25519 login challenge');
                    assert.ok(message.nonce && message.node && message.node.peerId.startsWith('12D3KooW'));
                    console.log(`PASS: public ${address}, TLS handshake, HTTP 101 and node challenge (node ${message.node.peerId}).`);
                    finish();
                } catch (error) {
                    finish(error);
                }
            };
            socket.on('data', receive);
            socket.on('error', finish);
            socket.on('end', () => finish(new Error('Socket closed before challenge')));
            receive(head);
        });
        request.end();
    });
}

async function main() {
    verifySource();
    if (!process.argv.includes('--live')) return;
    const addresses = await publicAddresses();
    console.log(`Public DNS (ignoring local hosts): ${addresses.join(', ')}`);
    let failed = false;
    for (const address of addresses) {
        try {
            await verifyPublicSnapshot(address);
        } catch (error) {
            failed = true;
            console.error(`FAIL: ${address}: ${error.message}`);
        }
    }
    if (failed) process.exitCode = 1;
}

main().catch(error => {
    console.error(`FAIL: ${error.message}`);
    process.exitCode = 1;
});
