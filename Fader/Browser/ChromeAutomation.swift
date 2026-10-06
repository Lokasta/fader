import AppKit
import Carbon
import Foundation
import os

struct ChromeTabUpdate: Codable, Equatable {
    let id: String
    let windowID: Int
    let documentID: String
    var volume: Double
    var muted: Bool
    var restore = false
}

struct ChromeTabReply: Decodable {
    var tabs: [ChromeTab]
    var javascriptBlocked: Bool
    var unavailableTabIDs: [String] = []
}

extension ChromeTabReply {
    private enum CodingKeys: String, CodingKey { case tabs, javascriptBlocked, unavailableTabIDs }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try values.decode([ChromeTab].self, forKey: .tabs)
        javascriptBlocked = try values.decode(Bool.self, forKey: .javascriptBlocked)
        unavailableTabIDs = try values.decodeIfPresent([String].self, forKey: .unavailableTabIDs) ?? []
    }
}

protocol ChromeTabClient {
    var isRunning: Bool { get }
    func authorize() async throws
    func execute(updates: [ChromeTabUpdate], scanAll: Bool, leaseID: String) async throws -> ChromeTabReply
}

extension ChromeTabClient {
    func authorize() async throws {}
}

/// Runs one bounded Apple Events batch off the UI thread. No extension, debug port or network.
final class ChromeAutomation: ChromeTabClient, @unchecked Sendable {
    static let bundleID = "com.google.Chrome"
    private static let queue = DispatchQueue(label: "com.lokasta.fader.chrome", qos: .userInitiated)
    private static let log = Logger(subsystem: "com.lokasta.fader", category: "chrome")
    // Accessed only on queue. Sleeping/discarded tabs must not delay every refresh.
    private var retryAfter: [String: Date] = [:]

    enum Failure: Error { case automationDenied, javascriptDisabled, timedOut, unavailable }

    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }

    func authorize() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.queue.async {
                guard let target = NSAppleEventDescriptor(descriptorType: typeApplicationBundleID, data: Data(Self.bundleID.utf8)) else {
                    return continuation.resume(throwing: Failure.unavailable)
                }
                let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
                if status == noErr { continuation.resume() }
                else { continuation.resume(throwing: Failure.automationDenied) }
            }
        }
    }

    func execute(updates: [ChromeTabUpdate], scanAll: Bool, leaseID: String) async throws -> ChromeTabReply {
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { [self] in
                do {
                    let now = Date()
                    let changed = Set(updates.map(\.id))
                    let skipped = retryAfter.filter { $0.value > now && !changed.contains($0.key) }.map(\.key)
                    let script = try Self.script(updates: updates, scanAll: scanAll, leaseID: leaseID, skippedTabIDs: skipped)
                    let reply = try Self.run(script, updates: updates, leaseID: leaseID, skippedTabIDs: Set(skipped))
                    let unavailable = Set(reply.unavailableTabIDs)
                    retryAfter = retryAfter.filter { unavailable.contains($0.key) }
                    for id in unavailable where !skipped.contains(id) { retryAfter[id] = now.addingTimeInterval(15) }
                    if !unavailable.isEmpty && skipped.isEmpty {
                        Self.log.info("Chrome scan: \(reply.tabs.count, privacy: .public) responding tabs, \(unavailable.count, privacy: .public) unavailable")
                    }
                    continuation.resume(returning: reply)
                } catch {
                    Self.log.error("Chrome batch failed: \(String(describing: error), privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func script(updates: [ChromeTabUpdate], scanAll: Bool, leaseID: String, skippedTabIDs: [String] = []) throws -> String {
        guard let url = Bundle.main.url(forResource: "ChromeMedia", withExtension: "js"),
              let media = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.unavailable }
        struct Request: Encodable {
            let updates: [ChromeTabUpdate]
            let scanAll: Bool
            let leaseID: String
            let media: String
            let skippedTabIDs: [String]
        }
        let data = try JSONEncoder().encode(Request(updates: updates, scanAll: scanAll, leaseID: leaseID, media: media, skippedTabIDs: skippedTabIDs))
        let json = String(decoding: data, as: UTF8.self)
        return """
        const request = \(json);
        const chrome = Application('com.google.Chrome');
        const tabs = [];
        if (chrome.running()) {
            const updates = new Set(request.updates.map(update => update.id));
            for (const window of chrome.windows()) {
                const windowID = Number(window.id());
                for (const tab of window.tabs()) {
                    const id = String(tab.id());
                    if (!request.scanAll && !updates.has(id)) continue;
                    try { tabs.push({ id, windowID, title: tab.title(), url: tab.url() }); }
                    catch (_) { /* The tab can close while we read its metadata. */ }
                }
            }
        }
        JSON.stringify(tabs);
        """
    }

    struct TabInfo: Decodable {
        let id: String
        let windowID: Int
        let title: String
        let url: String
    }

    private struct Sample: Decodable {
        let documentID: String
        let playingCount: Int
        let hasVideo: Bool
        let volume: Double
        let muted: Bool
    }

    private struct Command: Encodable {
        let leaseID: String
        let action: String
        var documentID: String?
        var volume: Double?
        var muted: Bool?
    }

    static func javascriptEvent(windowID: Int, tabID: String, javascript: String) -> NSAppleEventDescriptor {
        func object(_ kind: OSType, container: NSAppleEventDescriptor, id: String) -> NSAppleEventDescriptor {
            let record = NSAppleEventDescriptor.record()
            record.setDescriptor(NSAppleEventDescriptor(typeCode: kind), forKeyword: AEKeyword(keyAEDesiredClass))
            record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formUniqueID)), forKeyword: AEKeyword(keyAEKeyForm))
            record.setDescriptor(NSAppleEventDescriptor(string: id), forKeyword: AEKeyword(keyAEKeyData))
            record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
            return record.coerce(toDescriptorType: typeObjectSpecifier)!
        }
        let window = object(cWindow, container: NSAppleEventDescriptor.null(), id: String(windowID))
        let tab = object(0x43725462, container: window, id: tabID) // CrTb, Chrome's tab class.
        let event = NSAppleEventDescriptor(eventClass: 0x43725375, eventID: 0x45784A61,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID), returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(tab, forKeyword: keyDirectObject)
        event.setParam(NSAppleEventDescriptor(string: javascript), forKeyword: 0x4A765363) // JvSc.
        return event
    }

    private static func sample(_ tab: TabInfo, media: String, command: Command, sendEvent: EventSender) throws -> Data {
        let json = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        let event = javascriptEvent(windowID: tab.windowID, tabID: tab.id, javascript: media + "(" + json + ")")
        // Chrome never replies for some discarded/sleeping renderers. Bound each event,
        // rather than discarding every healthy tab when one tab doesn't respond.
        let reply = try sendEvent(event, 0.3)
        if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
        }
        guard let value = reply.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { throw Failure.unavailable }
        return Data(value.utf8)
    }

    private static func run(_ script: String, updates: [ChromeTabUpdate], leaseID: String, skippedTabIDs: Set<String>) throws -> ChromeTabReply {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        // Drain stdout before waiting: a browser with many tabs can fill a pipe buffer.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            if errorText.contains("-1743") { throw Failure.automationDenied }
            if errorText.contains("-10004") { throw Failure.javascriptDisabled }
            if process.terminationReason == .uncaughtSignal { throw Failure.timedOut }
            throw Failure.unavailable
        }
        guard let info = try? JSONDecoder().decode([TabInfo].self, from: data),
              let url = Bundle.main.url(forResource: "ChromeMedia", withExtension: "js"),
              let media = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.unavailable }
        return try probe(info, media: media, updates: updates, leaseID: leaseID, skippedTabIDs: skippedTabIDs)
    }

    typealias EventSender = (NSAppleEventDescriptor, TimeInterval) throws -> NSAppleEventDescriptor

    static func probe(_ info: [TabInfo], media: String, updates: [ChromeTabUpdate], leaseID: String, skippedTabIDs: Set<String> = [],
                      sendEvent: EventSender = { try $0.sendEvent(options: [.waitForReply, .neverInteract], timeout: $1) }) throws -> ChromeTabReply {
        let changes = Dictionary(updates.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var reply = ChromeTabReply(tabs: [], javascriptBlocked: false)
        for tab in info {
            if skippedTabIDs.contains(tab.id) { reply.unavailableTabIDs.append(tab.id); continue }
            let update = changes[tab.id]
            let command = Command(leaseID: leaseID, action: update.map { $0.restore ? "release" : "set" } ?? "probe",
                documentID: update?.documentID, volume: update?.volume, muted: update?.muted)
            do {
                var data = try sample(tab, media: media, command: command, sendEvent: sendEvent)
                let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if result?["released"] as? Bool == true || result?["stale"] as? Bool == true {
                    data = try sample(tab, media: media, command: Command(leaseID: leaseID, action: "probe"), sendEvent: sendEvent)
                }
                let value = try JSONDecoder().decode(Sample.self, from: data)
                reply.tabs.append(ChromeTab(id: tab.id, windowID: tab.windowID, documentID: value.documentID,
                    title: tab.title, url: tab.url, playingCount: value.playingCount,
                    hasVideo: value.hasVideo, volume: value.volume, muted: value.muted))
            } catch {
                switch (error as NSError).code {
                case 12, -10004: reply.javascriptBlocked = true
                case -1743: throw Failure.automationDenied
                case -1712: reply.unavailableTabIDs.append(tab.id)
                default: break // Closed, navigated or unsupported tabs don't block the rest.
                }
            }
        }
        return reply
    }
}
