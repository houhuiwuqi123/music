const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const https = require('node:https');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const service = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Services', 'CandyPlazaService.swift'), 'utf8');
const view = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Views', 'CandyPlazaView.swift'), 'utf8');
const plist = fs.readFileSync(path.join(root, 'AURU MUSIC', 'Info.plist'), 'utf8');

function verifySource() {
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
    assert.ok(service.includes('guard self.servingPeers[remoteID] === peer'));
    assert.ok(service.includes('guard self.fetchingPeers[remoteID] === peer'));
    assert.match(service, /func retryConnection\(\) \{\s+stop\(\)\s+start\(\)/);
    assert.ok(view.includes('plaza.connectionError') && view.includes('plaza.retryConnection()'));
    assert.ok(!plist.includes('NSExceptionAllowsInsecureHTTPLoads'));
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
