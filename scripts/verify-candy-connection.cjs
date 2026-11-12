const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const https = require('node:https');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const service = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Services', 'CandyPlazaService.swift'), 'utf8');
const transfer = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Services', 'CandyReliableTransfer.swift'), 'utf8');
const view = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Views', 'CandyPlazaView.swift'), 'utf8');
const globe = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Views', 'CandyGlobeView.swift'), 'utf8');
const land = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Views', 'CandyEarthLand.swift'), 'utf8');
const preview = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Services', 'CandyPreviewPlayer.swift'), 'utf8');
const plist = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Info.plist'), 'utf8');

function verifyViewScopes(source) {
    // This limited structural check is not a Swift parser or type-checker.
    const code = source.replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*|"(?:\\.|[^"\\])*"/g, '');
    const required = new Set(['CandyPlazaView', 'CandyListenerRow', 'CandyPreviewBar', 'CandyProfileView']);
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

function verifyGlobe() {
    // Land data decodes to closed rings of valid coordinates, Antarctica reaching the pole.
    const encoded = [...land.matchAll(/^\s+"([A-Za-z0-9+/=]+)"/gm)].map(m => m[1]).join('');
    const data = Buffer.from(encoded, 'base64');
    assert.ok(data.length > 10000 && data.length % 4 === 0, 'land data size');
    let rings = 0, points = 0, minLat = 90;
    for (let i = 0; i < data.length; i += 4) {
        const lon = data.readInt16LE(i), lat = data.readInt16LE(i + 2);
        if (lon === 32767 && lat === 32767) { rings++; continue; }
        assert.ok(Math.abs(lon) <= 18000 && Math.abs(lat) <= 9000, 'land coordinate range');
        minLat = Math.min(minLat, lat / 100);
        points++;
    }
    assert.ok(rings > 100 && points > 4000 && minLat === -90, `land rings ${rings}, points ${points}`);
    assert.equal(data.readInt16LE(data.length - 4), 32767, 'last ring terminated');

    // Mesh vertices, texture and markers share one lat/lon mapping.
    assert.ok(globe.includes('Float(radius * cos(lat) * sin(lon)), Float(radius * sin(lat)), Float(radius * cos(lat) * cos(lon))'));
    assert.ok(globe.includes('uvs.append(CGPoint(x: Double(j) / Double(slices), y: Double(i) / Double(stacks)))'));
    assert.ok(globe.includes('let lat = 90 - 180 * Double(i) / Double(stacks)') && globe.includes('let lon = -180 + 360 * Double(j) / Double(slices)'));
    assert.ok(globe.includes('CGPoint(x: (point.0 + 180) / 360 * size.width, y: (90 - point.1) / 180 * size.height)'));
    assert.ok(globe.includes('cg.fillPath(using: .evenOdd)'));
    // Focusing a place: yaw = -lon then pitch = lat must bring it to the front (0, 0, 1).
    assert.ok(globe.includes('let wantedYaw = Float(-longitude * .pi / 180)') && globe.includes('Float(max(-60, min(60, latitude)) * .pi / 180)'));
    assert.ok(globe.includes('pitchNode.eulerAngles = SCNVector3(pitch, 0, 0)') && globe.includes('yawNode.eulerAngles = SCNVector3(0, yaw, 0)'));
    const rad = d => d * Math.PI / 180;
    for (const [la, lo] of [[0, 0], [31.2, 121.5], [-33.9, 18.4], [51.5, -0.1], [60, -150]]) {
        const lat = rad(la), lon = rad(lo);
        let [x, y, z] = [Math.cos(lat) * Math.sin(lon), Math.sin(lat), Math.cos(lat) * Math.cos(lon)];
        const b = -lon; // rotation about Y
        [x, z] = [x * Math.cos(b) + z * Math.sin(b), -x * Math.sin(b) + z * Math.cos(b)];
        const a = lat; // rotation about X
        [y, z] = [y * Math.cos(a) - z * Math.sin(a), y * Math.sin(a) + z * Math.cos(a)];
        assert.ok(Math.abs(x) < 1e-9 && Math.abs(y) < 1e-9 && Math.abs(z - 1) < 1e-9, `focus ${la},${lo}`);
    }
    // Markers come from signed coarse geo; one dot per 0.1° place.
    assert.ok(view.includes('String(format: "%.1f,%.1f", lat, lon)') && view.includes('CandyGlobeView(markers: places'));
    assert.ok(service.includes('geo = try? c.decodeIfPresent([Double].self, forKey: .geo)'));
    assert.ok(service.includes('geo: visible ? geo : nil'));

    // Listen-while-downloading serves verified bytes only, and switches to the saved file.
    assert.ok(preview.includes('while data.currentOffset < min(end, available)'));
    assert.ok(preview.includes('loader?.update(available: file.size, source: url)'));
    assert.ok(transfer.includes('reportVerified(job, min(size, Int64(blockIndex) * Int64(candyBlockSize)))'));
    assert.ok(transfer.indexOf('guard digest == blocks[blockIndex]') < transfer.indexOf('reportVerified(job, min(size'), 'report after the block check');
    assert.ok(service.includes('preview.stream(file, partial: transfers.partialURL(for: file)'));
    assert.ok(view.includes('plaza.listen(file)') && view.includes('if playing { plaza.preview.pause() }'));
}

function verifySource() {
    verifyViewScopes(view);
    assert.throws(() => verifyViewScopes(view.replace('private struct CandyProfileView', '{ private struct CandyProfileView')));
    verifyGlobe();
    assert.ok(!view.includes('plaza.connectionError') && !view.includes('connectionTimeout'));
    assert.ok(!plist.includes('NSExceptionAllowsInsecureHTTPLoads'));
    const rootView = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Views', 'RootView.swift'), 'utf8');
    assert.ok(rootView.includes('Publishers.CombineLatest(player.$currentTrack, player.$isPlaying)'));
    assert.ok(rootView.includes('plaza.start()'));
    const settingsView = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Views', 'SettingsView.swift'), 'utf8');
    assert.ok(settingsView.includes('plaza.setSharesListening($0)') && view.includes('ForEach(listedListeners)'));
    assert.ok(view.includes('listener.region ?? "地区未知"'));
    assert.ok(view.includes('download: { selectedFile = listener.file }'));
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
    for (const file of ['CandyPlazaService', 'CandyPreviewPlayer', 'CandyGlobeView', 'CandyEarthLand']) {
        assert.equal((project.match(new RegExp(`${file}.swift in Sources`, 'g')) || []).length, 2, `${file} in Xcode target`);
    }
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
