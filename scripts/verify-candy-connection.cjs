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
    assert.ok(service.includes('URLComponents(string: "wss://music.webtrc.eu.cc/ws")'));
    assert.ok(service.includes('URLQueryItem(name: "id", value: clientID)'));
    assert.ok(service.includes('15_000_000_000'));
    assert.ok(service.includes('3_000_000_000'));
    assert.ok(service.includes('connectionTimeoutTask?.cancel()'));
    assert.match(service, /let message = try await task.receive\(\)\s+guard self.hasStarted, self.socket === task/);
    assert.match(service, /case "plaza":\s+connectionTimeoutTask\?\.cancel\(\)[\s\S]*?connectionState = \.connected/);
    assert.ok(service.includes('files = message.files ?? []'));
    assert.ok(service.includes('failure.domain') && service.includes('failure.code') && service.includes('HTTPURLResponse'));
    assert.ok(service.includes('self.disconnect(socket, message:'));
    assert.ok(service.includes('self.disconnect(task, message:'));
    assert.ok(transfer.includes('self.peers[grant.id] === peer'));
    assert.match(service, /func retryConnection\(\) \{\s*stop\(\);\s*start\(\)/);
    assert.ok(!view.includes('plaza.connectionError') && !view.includes('connectionTimeout'));
    assert.ok(!plist.includes('NSExceptionAllowsInsecureHTTPLoads'));
    assert.ok(service.includes('as? Bool ?? true'));
    assert.ok(service.includes('userDefaults.set(enabled, forKey: "candy_shares_listening")'));
    assert.ok(service.includes('var state = sharesListening ? localListening : nil'));
    assert.ok(service.includes('state?.file = shares.values.first'));
    assert.ok(service.includes('30_000_000_000'));
    assert.ok(service.includes('case "listeners":'));
    assert.ok(service.includes('.filter { $0.clientId != clientID }'));
    assert.ok(service.includes('if firstSnapshot { sendListening() }'));
    const listeningUpdate = service.slice(service.indexOf('func updateListening('), service.indexOf('private func sendListening('));
    assert.ok(!listeningUpdate.includes('artworkData'));
    const rootView = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Views', 'RootView.swift'), 'utf8');
    assert.ok(rootView.includes('Publishers.CombineLatest(player.$currentTrack, player.$isPlaying)'));
    assert.ok(rootView.includes('plaza.start()'));
    const settingsView = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Views', 'SettingsView.swift'), 'utf8');
    assert.ok(settingsView.includes('plaza.setSharesListening($0)') && view.includes('ForEach(visibleListeners)'));
    assert.ok(!view.includes('CandyPublishPanelView') && !view.includes('showsPublishPanel'));
    assert.ok(view.includes('listener.region ?? "地区未知"'));
    assert.ok(view.includes('.id(listener.id)'));
    assert.ok(view.includes('action: { selectedFile = listener.file }'));
    assert.ok(service.includes('self.transfers.publish(file, url: track.fileURL)'));
    const automaticShare = service.slice(service.indexOf('private func synchronizeAutomaticShare()'), service.indexOf('func download('));
    assert.ok(automaticShare.includes('shares.removeAll()'));
    assert.ok(!automaticShare.includes('removeItem') && !automaticShare.includes('copyItem'));
    assert.ok(view.includes('paused: listener.isOffline'));
    assert.ok(view.includes('CandyProfileView'));
    assert.ok(view.includes('Button("下载")') && view.includes('Button("取消", role: .cancel)'));
    assert.ok(view.includes('.truncationMode(.tail)'));
    assert.doesNotMatch(service, /preview|AVAudioConverter|AVAudioPlayerNode|试听/i);
    assert.doesNotMatch(view, /preview|试听/i);
    assert.ok(transfer.includes('dataChannel(forLabel: "file-v2:\\(grant.id)"'));
    assert.ok(transfer.includes('channel.label == "file-v2:\\(id)"'));
    assert.ok(service.includes('try identitySecret()') && service.includes('SecItemAdd'));
    assert.ok(transfer.includes('jobs.count < 2') && transfer.includes('uploads.count < 1'));
    assert.ok(transfer.includes('incomingBytes + buffer.data.count <= 2_097_152'));
    assert.ok(transfer.includes('try handle?.synchronize()'));
    assert.ok(transfer.includes('digest() == file.sha256'));
    assert.ok(transfer.includes('SHA256.hash') && transfer.includes('prefixHash'));
    assert.ok(transfer.includes('forHTTPHeaderField: "Range"'));
    assert.ok(transfer.includes('forHTTPHeaderField: "Content-Range"'));
    assert.ok(transfer.includes('forHTTPHeaderField: "If-Match"'));
    assert.ok(transfer.includes('type: "transfer-complete"'));
    assert.ok(transfer.includes('type: "complete"'));
    assert.ok(transfer.includes('case "transfer-revoked":'));
    assert.ok(transfer.includes('job.generation = generation') && transfer.includes('grant.generation == signal.generation'));
    assert.ok(transfer.includes('job.requestID = UUID().uuidString.lowercased()'));
    assert.ok(service.includes('type: "share-retire"') && service.includes('type: "lease-refresh"'));
    assert.ok(transfer.includes('type: "source-unavailable"') && transfer.includes('type: "upload-error"'));
    assert.ok(transfer.includes('func publish(') && !transfer.slice(transfer.indexOf('func publish('), transfer.indexOf('func withdraw(')).includes('closePeer'));
    const project = fs.readFileSync(path.join(root, 'MusicPlayer.xcodeproj', 'project.pbxproj'), 'utf8');
    assert.equal((project.match(/CandyReliableTransfer.swift in Sources/g) || []).length, 2);
    assert.ok(view.includes('plaza.cancelDownload(download.id)') && view.includes('plaza.retryDownload(download.file)'));
    assert.ok(service.includes('now - $0 >= 60'));
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
            path: `/ws?id=${crypto.randomUUID()}`,
            headers: {
                Host: 'music.webtrc.eu.cc',
                Connection: 'Upgrade',
                Upgrade: 'websocket',
                'Sec-WebSocket-Version': '13',
                'Sec-WebSocket-Key': key
            }
        });
        const timer = setTimeout(() => finish(new Error('No WebSocket snapshot within 30 seconds')), 30000);
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
                    assert.equal(data[0], 0x81, 'Expected an unfragmented JSON text snapshot');
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
                        assert.ok(size <= 1048576n, 'Snapshot exceeds test limit');
                        length = Number(size);
                        offset = 10;
                    }
                    if (data.length < offset + length) return;
                    const message = JSON.parse(data.subarray(offset, offset + length).toString('utf8'));
                    assert.equal(message.type, 'plaza');
                    assert.ok(message.files === undefined || Array.isArray(message.files));
                    console.log(`PASS: public ${address}, TLS handshake, HTTP 101 and plaza snapshot (${(message.files || []).length} files).`);
                    finish();
                } catch (error) {
                    finish(error);
                }
            };
            socket.on('data', receive);
            socket.on('error', finish);
            socket.on('end', () => finish(new Error('Socket closed before snapshot')));
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
