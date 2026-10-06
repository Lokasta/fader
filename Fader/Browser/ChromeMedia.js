(function (request) {
    // Apple Events execute in Chrome's isolated world. This state is private to Fader,
    // while volume and mute are the media element's normal, shared player controls.
    const key = '__lokastaFaderMediaV1';
    let state = globalThis[key];
    if (!state) {
        state = globalThis[key] = {
            documentID: `${Date.now()}-${Math.random()}`,
            elements: new Map(),
            volume: 1,
            muted: false,
            leaseID: request.leaseID,
            watchdog: null
        };
    }

    function restore() {
        clearTimeout(state.watchdog);
        for (const [media, original] of state.elements) {
            // A site or the user may have changed its own player since our last poll.
            if (media.volume === original.appliedVolume) media.volume = original.volume;
            if (media.muted === original.appliedMuted) media.muted = original.muted;
        }
        state.elements.clear();
        state.volume = 1;
        state.muted = false;
    }

    if (state.leaseID !== request.leaseID) {
        restore();
        state.leaseID = request.leaseID;
    }
    // Tab IDs survive navigation. Never apply a queued slider change to a new page.
    if (request.documentID && request.documentID !== state.documentID) {
        return JSON.stringify({ stale: true });
    }
    if (request.action === 'release') {
        restore();
        return JSON.stringify({ released: true });
    }
    if (request.action === 'set') {
        state.volume = Math.max(0, Math.min(1, request.volume));
        state.muted = request.muted === true;
    }

    const mediaElements = [];
    const visited = new Set();
    function collect(root) {
        if (!root || visited.has(root)) return;
        visited.add(root);
        mediaElements.push(...root.querySelectorAll('audio, video'));
        for (const frame of root.querySelectorAll('iframe, frame')) {
            try { collect(frame.contentDocument); } catch (_) { /* Cross-origin frames stay untouched. */ }
        }
        for (const element of root.querySelectorAll('*')) {
            if (element.shadowRoot) collect(element.shadowRoot);
        }
    }
    collect(document);

    function hasAudio(media) {
        if (media.srcObject && typeof media.srcObject.getAudioTracks === 'function') {
            return media.srcObject.getAudioTracks().some(track => track.enabled && track.readyState === 'live');
        }
        if (media.tagName === 'AUDIO') return true;
        // A playing, silent video must not be mistaken for a tab producing audio.
        return (media.audioTracks && media.audioTracks.length > 0)
            || media.webkitAudioDecodedByteCount > 0;
    }
    function isPlaying(media) {
        return !media.paused && !media.ended && media.readyState >= 2 && hasAudio(media);
    }

    let playingCount = 0;
    let hasVideo = false;
    const controlled = state.volume < 1 || state.muted;
    for (const [media, original] of state.elements) {
        if (!media.isConnected) {
            // A player can temporarily leave the DOM and then return. Restore its baseline
            // before forgetting it, otherwise reattaching would apply the gain twice.
            if (media.volume === original.appliedVolume) media.volume = original.volume;
            if (media.muted === original.appliedMuted) media.muted = original.muted;
            state.elements.delete(media);
        }
    }
    for (const media of mediaElements) {
        let original = state.elements.get(media);
        if (original) {
            if (media.volume !== original.appliedVolume) original.volume = media.volume;
            if (media.muted !== original.appliedMuted) original.muted = media.muted;
        }
        const volume = original ? original.volume : media.volume;
        const muted = original ? original.muted : media.muted;
        const playing = isPlaying(media);
        // Keep a Fader-muted player discoverable so its unmute control doesn't disappear.
        if (playing && volume > 0 && !muted) {
            playingCount += 1;
            hasVideo = hasVideo || media.tagName === 'VIDEO';
        }
        if (controlled && (playing || original)) {
            if (!original) {
                original = { volume, muted };
                state.elements.set(media, original);
            }
            original.appliedVolume = original.volume * state.volume;
            original.appliedMuted = original.muted || state.muted;
            if (media.volume !== original.appliedVolume) media.volume = original.appliedVolume;
            if (media.muted !== original.appliedMuted) media.muted = original.appliedMuted;
        }
    }
    if (!controlled && state.elements.size) restore();
    if (controlled) {
        // Restore player settings if Fader crashes or loses contact with Chrome. Background
        // tabs may throttle this timer; regular polling keeps it alive while Fader runs.
        clearTimeout(state.watchdog);
        state.watchdog = setTimeout(restore, 12000);
    }
    return JSON.stringify({
        documentID: state.documentID,
        playingCount,
        hasVideo,
        volume: state.volume,
        muted: state.muted
    });
})
