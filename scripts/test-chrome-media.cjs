#!/usr/bin/env node
// Offline integration checks against real media elements in an isolated, muted browser.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const mediaScript = fs.readFileSync(path.join(__dirname, '../Fader/Browser/ChromeMedia.js'), 'utf8');

(async () => {
    const browser = await chromium.launch({
        ...(process.env.FADER_TEST_CHROME ? { channel: 'chrome' } : {}),
        headless: true,
        args: ['--mute-audio', '--autoplay-policy=no-user-gesture-required']
    });
    const deadline = setTimeout(() => {
        console.error('Chrome media tests exceeded 60 seconds.');
        process.exitCode = 1;
        void browser.close();
    }, 60000);
    try {
        const page = await browser.newPage();
        await page.route('**/*', route => route.abort());
        async function fixture() {
            await page.goto('about:blank');
            await page.evaluate(async () => {
                const rate = 8000, frames = rate * 30;
                const bytes = new ArrayBuffer(44 + frames * 2), view = new DataView(bytes);
                function text(offset, value) { [...value].forEach((c, i) => view.setUint8(offset + i, c.charCodeAt(0))); }
                text(0, 'RIFF'); view.setUint32(4, bytes.byteLength - 8, true); text(8, 'WAVE'); text(12, 'fmt ');
                view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
                view.setUint32(24, rate, true); view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
                text(36, 'data'); view.setUint32(40, frames * 2, true);
                for (let i = 0; i < frames; i++) view.setInt16(44 + i * 2, Math.sin(i * 2 * Math.PI * 440 / rate) * 1000, true);
                window.source = URL.createObjectURL(new Blob([bytes], { type: 'audio/wav' }));
                window.player = document.createElement('audio');
                player.src = source; player.volume = 0.8; player.loop = true;
                document.body.append(player);
                await player.play();
            });
        }
        async function run(command = {}) {
            return page.evaluate(({ source, request }) => JSON.parse((0, eval)(source)(request)), {
                source: mediaScript, request: { leaseID: 'test', action: 'probe', ...command }
            });
        }
        async function values() { return page.evaluate(() => ({ volume: player.volume, muted: player.muted })); }
        let checks = 0;
        function pass(name) { checks++; console.log(`PASS ${name}`); }

        await fixture();
        let sample = await run();
        assert.equal(sample.playingCount, 1);
        assert.deepEqual(await values(), { volume: 0.8, muted: false });
        pass('discovery leaves an audible player untouched');

        sample = await run({ action: 'set', documentID: sample.documentID, volume: 0.25, muted: false });
        assert.deepEqual(await values(), { volume: 0.2, muted: false });
        pass('tab volume scales the existing site volume');
        sample = await run({ action: 'set', volume: 0.25, muted: true });
        assert.equal(sample.playingCount, 1);
        assert.equal((await values()).muted, true);
        pass('Fader-muted tabs remain discoverable for unmute');

        await run({ action: 'release', documentID: sample.documentID });
        assert.deepEqual(await values(), { volume: 0.8, muted: false });
        pass('release restores player volume and mute');

        await page.evaluate(() => { player.muted = true; });
        assert.equal((await run()).playingCount, 0);
        await page.evaluate(() => { player.muted = false; player.pause(); });
        assert.equal((await run()).playingCount, 0);
        await page.evaluate(() => { player.currentTime = player.duration; });
        assert.equal((await run()).playingCount, 0);
        pass('site-muted, paused and ended players are excluded');

        await page.evaluate(async () => { player.currentTime = 0; await player.play(); });
        sample = await run({ action: 'set', volume: 0, muted: false });
        assert.equal(sample.playingCount, 1);
        assert.equal((await values()).volume, 0);
        await run({ action: 'set', volume: 1, muted: false });
        assert.equal((await values()).volume, 0.8);
        pass('zero volume can be recovered and reset restores the baseline');

        await run({ action: 'set', volume: 0.5, muted: false });
        await page.evaluate(() => { player.volume = 0.6; });
        await run();
        assert.equal((await values()).volume, 0.3);
        await run({ action: 'release' });
        assert.equal((await values()).volume, 0.6);
        pass('site volume changes survive release');

        await run({ action: 'set', volume: 0.5, muted: false });
        await page.evaluate(async () => {
            window.second = document.createElement('audio'); second.src = source; second.volume = 0.4;
            document.body.append(second); await second.play();
        });
        sample = await run();
        assert.equal(sample.playingCount, 2);
        assert.equal(await page.evaluate(() => second.volume), 0.2);
        await run({ action: 'release' });
        assert.equal(await page.evaluate(() => second.volume), 0.4);
        pass('new playing media in the tab receives its existing adjustment');

        await run({ action: 'set', volume: 0.5, muted: false });
        await page.evaluate(() => { second.pause(); second.remove(); });
        await run();
        assert.equal(await page.evaluate(() => second.volume), 0.4);
        await page.evaluate(async () => { document.body.append(second); await second.play(); });
        await run();
        assert.equal(await page.evaluate(() => second.volume), 0.2);
        await run({ action: 'release' });
        pass('temporarily removed players are not attenuated twice when reattached');

        await fixture();
        await page.evaluate(async () => {
            player.pause();
            const canvas = document.createElement('canvas'); canvas.width = 16; canvas.height = 16;
            const drawing = canvas.getContext('2d');
            window.frameTimer = setInterval(() => drawing.fillRect(0, 0, 16, 16), 50);
            window.silentVideo = document.createElement('video'); silentVideo.srcObject = canvas.captureStream(5);
            document.body.append(silentVideo); await silentVideo.play();
        });
        assert.equal((await run()).playingCount, 0);
        pass('a playing video without audio is excluded');

        await fixture();
        await page.evaluate(async () => {
            player.pause();
            const context = new AudioContext(); await context.resume();
            const sound = context.createMediaStreamDestination();
            const oscillator = context.createOscillator(); oscillator.connect(sound); oscillator.start();
            const canvas = document.createElement('canvas'); canvas.width = 16; canvas.height = 16;
            const drawing = canvas.getContext('2d');
            const frames = setInterval(() => drawing.fillRect(0, 0, 16, 16), 40);
            const stream = new MediaStream([...canvas.captureStream(5).getVideoTracks(), ...sound.stream.getAudioTracks()]);
            const chunks = [];
            const recorder = new MediaRecorder(stream, { mimeType: 'video/webm;codecs=vp8,opus' });
            recorder.ondataavailable = event => chunks.push(event.data);
            const stopped = new Promise(resolve => { recorder.onstop = resolve; });
            recorder.start(); await new Promise(resolve => setTimeout(resolve, 500)); recorder.stop(); await stopped;
            clearInterval(frames); stream.getTracks().forEach(track => track.stop()); await context.close();
            window.video = document.createElement('video');
            video.src = URL.createObjectURL(new Blob(chunks, { type: 'video/webm' })); video.loop = true;
            document.body.append(video); await video.play();
        });
        await page.waitForFunction(() => video.webkitAudioDecodedByteCount > 0);
        sample = await run();
        assert.equal(sample.playingCount, 1);
        assert.equal(sample.hasVideo, true);
        pass('video playback with a decoded audio track is detected');

        await fixture();
        await page.evaluate(async () => {
            player.pause();
            const frame = document.createElement('iframe'); frame.srcdoc = '<body></body>';
            const loaded = new Promise(resolve => { frame.onload = resolve; }); document.body.append(frame); await loaded;
            window.framed = frame.contentDocument.createElement('audio'); framed.src = source; framed.volume = 0.5;
            frame.contentDocument.body.append(framed); await framed.play();
            const host = document.createElement('div'); document.body.append(host);
            window.shadowed = document.createElement('audio'); shadowed.src = source; shadowed.volume = 0.6;
            host.attachShadow({ mode: 'open' }).append(shadowed); await shadowed.play();
        });
        sample = await run({ action: 'set', volume: 0.5, muted: false });
        assert.equal(sample.playingCount, 2);
        assert.deepEqual(await page.evaluate(() => [framed.volume, shadowed.volume]), [0.25, 0.3]);
        await run({ action: 'release' });
        assert.deepEqual(await page.evaluate(() => [framed.volume, shadowed.volume]), [0.5, 0.6]);
        pass('same-origin frames and open shadow-root players are controlled');

        await fixture();
        sample = await run({ action: 'set', volume: 0.25, muted: true });
        await run({ leaseID: 'another-fader' });
        assert.deepEqual(await values(), { volume: 0.8, muted: false });
        pass('a new Fader session releases settings left by the old session');

        await fixture();
        sample = await run();
        await fixture();
        const stale = await run({ action: 'set', documentID: sample.documentID, volume: 0.1, muted: true });
        assert.equal(stale.stale, true);
        assert.deepEqual(await values(), { volume: 0.8, muted: false });
        pass('navigation rejects commands for the previous document');

        await run({ action: 'set', volume: 0.5, muted: false });
        await page.evaluate(() => { player.volume = 0.9; player.muted = true; });
        await run({ action: 'release' });
        assert.deepEqual(await values(), { volume: 0.9, muted: true });
        pass('release does not overwrite newer player edits');
        console.log(`${checks} Chrome media checks passed.`);
    } finally { clearTimeout(deadline); await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
