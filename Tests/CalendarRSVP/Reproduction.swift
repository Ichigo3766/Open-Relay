import Foundation

@main struct Reproduction {
    static func main() throws {
        let data = Data(#"{"id":"paper-series","calendar_id":"crafts","title":"Paper workshop","start_at":0,"all_day":false,"attendees":[{"id":"invite","event_id":"paper-series","user_id":"demo-user","status":"tentative"}]}"#.utf8)
        let event = try JSONDecoder().decode(CalendarEvent.self, from: data)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
        guard let attendees = saved["attendees"] as? [[String: Any]], attendees.first?["status"] as? String == "tentative" else {
            print("FAIL: calendar attendee response disappears during decoding/encoding")
            exit(1)
        }
        print("PASS: calendar attendee response survives decoding/encoding")
    }
}
