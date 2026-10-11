const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');

const base = process.argv[2] || 'ws://127.0.0.1:18081/ws';
const clients = [];
async function connect(id = randomUUID()) {
    const url = new URL(base);
    url.searchParams.set('id', id);
    const socket = new WebSocket(url);
    const messages = [];
    socket.addEventListener('message', event => messages.push(JSON.parse(event.data)));
    const client = {
        id, socket, messages,
        send: message => socket.send(JSON.stringify(message)),
        async wait(predicate, start = 0) {
            const deadline = Date.now() + 5000;
            while (Date.now() < deadline) {
                const match = messages.slice(start).find(predicate);
                if (match) return match;
                await new Promise(resolve => setTimeout(resolve, 20));
            }
            throw new Error(`Missing expected message; received: ${JSON.stringify(messages.slice(start))}`);
        }
    };
    clients.push(client);
    await client.wait(message => message.type === 'plaza');
    await client.wait(message => message.type === 'listeners');
    return client;
}

async function main() {
    const a = await connect();
    const b = await connect();
    const song = { id: randomUUID(), name: 'song.mp3', size: 1024, ownerId: 'spoofed', ownerName: 'spoofed' };
    const avatar = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6WQAAAAASUVORK5CYII=';
    const state = { clientId: 'spoofed', region: 'spoofed', ownerName: 'Test visitor', title: 'Test song', artist: 'Test artist', isPlaying: true, file: song, avatar };
    a.send({ type: 'listening', listening: state });
    let snapshot = await b.wait(m => m.type === 'listeners' && m.listeners.some(s => s.clientId === a.id));
    assert.equal(snapshot.listeners.find(s => s.clientId === a.id).title, state.title);
    assert.ok(!snapshot.listeners.some(s => s.clientId === 'spoofed'));
    const listener = snapshot.listeners.find(s => s.clientId === a.id);
    assert.notEqual(listener.region, 'spoofed');
    assert.ok(listener.region);
    assert.equal(listener.file.ownerId, a.id);
    assert.equal(listener.file.ownerName, state.ownerName);
    assert.equal(listener.file.id, song.id);
    assert.equal(listener.avatar, avatar);
    assert.ok(!listener.offlineAt);
    assert.ok(!JSON.stringify(listener).includes('"ip":'));
    await b.wait(m => m.type === 'plaza' && m.files?.some(f => f.id === song.id));
    const rejectedStart = b.messages.length;
    b.send({ type: 'listening', listening: state });
    await b.wait(m => m.type === 'error' && m.error.includes('another client'), rejectedStart);
    console.log('PASS: broadcast, server-owned identity/region and file ownership rejection');
    const c = await connect();
    await c.wait(m => m.type === 'listeners' && m.listeners.some(s => s.title === state.title));
    console.log('PASS: newly connected client receives listening snapshot');
    let start = b.messages.length;
    a.send({ type: 'listening', listening: { ...state, isPlaying: false } });
    await b.wait(m => m.type === 'listeners' && m.listeners.some(s => s.clientId === a.id && !s.isPlaying), start);
    const paused = b.messages.slice(start).find(m => m.type === 'listeners');
    assert.equal(paused.listeners.find(s => s.clientId === a.id).file.id, song.id);
    start = b.messages.length;
    const nextSong = { ...song, id: randomUUID(), name: 'next.mp3' };
    a.send({ type: 'listening', listening: { ...state, title: 'Next song', file: nextSong } });
    await b.wait(m => m.type === 'listeners' && m.listeners.some(s => s.title === 'Next song'), start);
    await b.wait(m => m.type === 'plaza' && m.files?.some(f => f.id === nextSong.id) && !m.files.some(f => f.id === song.id), start);
    console.log('PASS: auto publish, region ownership, pause retains download and track change withdraws old file');
    start = b.messages.length;
    a.send({ type: 'listening' });
    await b.wait(m => m.type === 'listeners' && !m.listeners.some(s => s.clientId === a.id), start);
    await b.wait(m => m.type === 'plaza' && !(m.files || []).some(f => f.id === nextSong.id), start);
    console.log('PASS: privacy off / stopped playback removes state');
    a.send({ type: 'listening', listening: { ...state, title: '' } });
    await a.wait(m => m.type === 'error' && m.error);
    const avatarStart = a.messages.length;
    a.send({ type: 'listening', listening: { ...state, avatar: 'not-an-image' } });
    await a.wait(m => m.type === 'error' && m.error.includes('avatar'), avatarStart);
    console.log('PASS: invalid metadata rejected explicitly');
    start = b.messages.length;
    a.send({ type: 'listening', listening: state });
    await b.wait(m => m.type === 'listeners' && m.listeners.some(s => s.clientId === a.id), start);
    start = b.messages.length;
    a.socket.close();
    await b.wait(m => m.type === 'listeners' && m.listeners.some(s => s.clientId === a.id && s.offlineAt), start);
    await b.wait(m => m.type === 'plaza' && !(m.files || []).some(f => f.id === song.id), start);
    const reconnected = await connect(a.id);
    start = b.messages.length;
    reconnected.send({ type: 'listening', listening: state });
    await b.wait(m => m.type === 'listeners' && m.listeners.some(s => s.clientId === reconnected.id && !s.offlineAt), start);
    await b.wait(m => m.type === 'plaza' && m.files?.some(f => f.id === song.id && f.ownerId === reconnected.id), start);
    console.log('PASS: offline snapshot and reconnect with same star identity');
    const file = { id: randomUUID(), name: 'test.txt', size: 4, ownerName: 'Test visitor' };
    b.send({ type: 'publish', file });
    await c.wait(m => m.type === 'plaza' && m.files?.some(f => f.id === file.id));
    b.send({ type: 'signal', to: c.id, data: JSON.stringify({ kind: 'candidate', candidate: {} }) });
    await c.wait(m => m.type === 'signal' && m.from === b.id);
    const streamStart = c.messages.length;
    b.send({ type: 'signal', to: c.id, data: JSON.stringify({ kind: 'offer', sdp: { type: 'offer', sdp: 'file-channel-test' } }) });
    const signal = await c.wait(m => m.type === 'signal' && JSON.parse(m.data).kind === 'offer', streamStart);
    assert.equal(JSON.parse(signal.data).sdp.sdp, 'file-channel-test');
    start = c.messages.length;
    b.send({ type: 'unpublish', fileId: file.id });
    await c.wait(m => m.type === 'plaza' && !(m.files || []).some(f => f.id === file.id), start);
    console.log('PASS: existing publish, signal relay and unpublish preserved');
}

function finish(exitCode) {
    clients.forEach(client => client.socket.close());
    setTimeout(() => process.exit(exitCode), 1000);
}

main().then(() => finish(0)).catch(error => {
    console.error('FAIL:', error);
    finish(1);
});
