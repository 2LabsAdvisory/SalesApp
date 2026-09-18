import Foundation
import Security
import Testing
@testable import SalesApp

/// Where the session lives and how the API's answers are read (FR15 §3.3).
@Suite struct SessionTests {
    @Test func tokensAreInTheKeychainForThisDeviceOnly() async throws {
        let account = "test-\(UUID().uuidString)"
        let tokens = TokenStore(account: account)
        try await tokens.save(Credentials(bundle: .sample))
        defer { Task { await tokens.clear() } }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ca.2labs.sales",
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])

        // Readable after the first unlock — so Siri can send while locked —
        // and never carried by a backup to another phone.
        #expect(attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect((attributes[kSecAttrSynchronizable as String] as? Bool ?? false) == false)
    }

    @Test func nothingSensitiveIsInUserDefaults() async throws {
        let tokens = TokenStore(account: "test-\(UUID().uuidString)")
        try await tokens.save(Credentials(bundle: .sample))
        defer { Task { await tokens.clear() } }

        let everything = UserDefaults.standard.dictionaryRepresentation().description
        #expect(!everything.contains("access"), "a token found its way into UserDefaults")
        #expect(!everything.contains("refresh"))
    }

    @Test func signingOutForgetsTheSession() async throws {
        let account = "test-\(UUID().uuidString)"
        let tokens = TokenStore(account: account)
        try await tokens.save(Credentials(bundle: .sample))
        await tokens.clear()
        #expect(await tokens.current() == nil)
        // Gone from the Keychain too, not just from memory.
        #expect(await TokenStore(account: account).current() == nil)
    }

    @Test func pkceMatchesTheRFC() {
        // RFC 7636, appendix B.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

        // A fresh pair is the shape the API checks: 43 base64url characters.
        let fresh = PKCE()
        #expect(fresh.challenge.count == 43)
        #expect(fresh.verifier.count >= 43 && fresh.verifier.count <= 128)
        #expect(fresh.challenge.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func answersAreReadTheWayTheServerMeansThem() throws {
        #expect(throws: Never.self) { try APIClient.check(status: 201, data: Data()) }
        #expect(throws: Never.self) { try APIClient.check(status: 200, data: Data()) }

        let moved = Data(#"{"success":false,"code":"organization_changed","error":"x"}"#.utf8)
        #expect(throws: APIError.organizationChanged) { try APIClient.check(status: 409, data: moved) }

        let refused = Data(#"{"success":false,"error":"A note cannot be empty."}"#.utf8)
        #expect(throws: APIError.http(status: 400, message: "A note cannot be empty.")) {
            try APIClient.check(status: 400, data: refused)
        }
        #expect(throws: APIError.http(status: 502, message: "Something went wrong (502).")) {
            try APIClient.check(status: 502, data: Data("<html>".utf8))
        }
    }

    @Test func retriesBackOffAndStopAtHalfAnHour() {
        #expect(NoteSender.backoff(afterAttempts: 1) == 15)
        #expect(NoteSender.backoff(afterAttempts: 2) == 30)
        #expect(NoteSender.backoff(afterAttempts: 3) == 60)
        #expect(NoteSender.backoff(afterAttempts: 40) == 30 * 60)
    }
}

/// What the server sends, decoded as the app reads it.
@Suite struct DecodingTests {
    @Test func aNoteFromTheList() throws {
        let json = """
        {"data":[{"id":"n1","body":"Coffee with Priya.","source":"siri","status":"needs_look",
          "outcome":"meeting logged, 3 changes proposed","customer_id":null,"contact_id":null,
          "opportunity_id":null,"created_by":"u1","created_at":"2026-09-18T18:14:05.123Z",
          "client_id":"6f0c6a0e-3d0a-4d7c-9a54-3e1b0d6f2a11","captured_at":"2026-09-18T18:10:00.000Z",
          "customer_name":"Meridian Health Group","contact_name":null,"opportunity_name":null,
          "created_by_name":"Rob Tanaka"}],"total":1,"success":true}
        """
        let page = try JSONDecoder.api.decode(NotePage.self, from: Data(json.utf8))
        let note = try #require(page.data.first)
        #expect(note.status == .needsLook)
        #expect(note.status.needsAttention)
        #expect(note.source == .siri)
        #expect(note.customerName == "Meridian Health Group")
        // When it was said, not when it arrived.
        #expect(note.saidAt == APIDate.parse("2026-09-18T18:10:00.000Z"))
    }

    @Test func aTypedNoteWithoutCaptureTime() throws {
        let json = """
        {"data":{"id":"n2","body":"Kembridge budget resets in January.","source":"typed","status":"logged",
          "outcome":"Note kept","created_at":"2026-09-18T18:14:05Z","captured_at":null,"client_id":null,
          "customer_name":null,"contact_name":null,"opportunity_name":null}}
        """
        let note = try JSONDecoder.api.decode(DataEnvelope<Note>.self, from: Data(json.utf8)).data
        #expect(note.saidAt == note.createdAt)
        #expect(!note.status.needsAttention)
    }

    @Test func theBodyAPhoneSendsIsWhatTheServerReads() throws {
        struct Body: Encodable { let body: String; let source: NoteSource; let clientId: String; let capturedAt: Date }
        let data = try JSONEncoder.api.encode(Body(
            body: "x", source: .appRecorder, clientId: "id", capturedAt: Date(timeIntervalSince1970: 0)))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["source"] as? String == "app_recorder")
        #expect(object["client_id"] as? String == "id")
        #expect(object["captured_at"] as? String == "1970-01-01T00:00:00.000Z")
    }
}

/// How notes read in the list, and what Siri says.
@Suite struct WordingTests {
    let calendar = Calendar(identifier: .gregorian)

    @Test func timesReadAsThePrototypeWritesThem() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 16)))
        let afternoon = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 14, minute: 14)))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 11, minute: 2)))
        let yesterday = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 9)))
        #expect(NoteFormat.when(afternoon, now: now, calendar: calendar) == "2:14p")
        #expect(NoteFormat.when(morning, now: now, calendar: calendar) == "11:02a")
        #expect(NoteFormat.when(yesterday, now: now, calendar: calendar) == "Yesterday")
    }

    @Test func excerptsStopAtAWord() {
        let excerpt = NoteFormat.excerpt("Coffee with Priya, they want the two new clinics in Red Deer and more", limit: 45)
        #expect(excerpt == "“Coffee with Priya, they want the two new…”")
        #expect(NoteFormat.excerpt("Short.") == "“Short.”")
    }

    @Test func siriSaysOneSentenceAndNeverReadsTheNoteBack() {
        for outcome in [CaptureService.Outcome.saved(organizationName: "Kestrel"), .savedAwaitingSignIn, .nothingHeard] {
            let reply = TakeNoteIntent.reply(to: outcome)
            let sentences = reply.split(whereSeparator: { ".!?".contains($0) })
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            #expect(sentences.count == 1, "\(reply)")
            #expect(!reply.contains("Kestrel"), "Siri named the org: \(reply)")
        }
    }
}
