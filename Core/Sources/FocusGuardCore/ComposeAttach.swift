import Foundation

/// Getting a draft's images into X's post box. The address that opens the
/// box can carry text and nothing else, so the images go by the clipboard:
/// they are copied, and once the box is on screen the browser is told to
/// paste, exactly as ⌘V would. Only Chrome and its relatives take that
/// instruction from another app. Nothing here presses Post.
///
/// It is done in two scripts with the app in between, so the app can check
/// that the clipboard still holds the images before anything is pasted.
public enum ComposeAttach {
    /// The compose tab, once it has loaded.
    public struct Target: Equatable {
        public let window: Int
        public let tab: Int
        /// Whether the browser lets a script look at the page. Chrome has a
        /// setting for it, off unless the person turned it on. Without it the
        /// paste still happens; it just can't be checked.
        public let canLook: Bool
        /// Whether the post box was seen on the page.
        public let boxFound: Bool
        /// Images already in the box before anything was pasted.
        public let alreadyAttached: Int

        public init(window: Int, tab: Int, canLook: Bool, boxFound: Bool, alreadyAttached: Int) {
            self.window = window
            self.tab = tab
            self.canLook = canLook
            self.boxFound = boxFound
            self.alreadyAttached = alreadyAttached
        }
    }

    public enum Outcome: Equatable {
        /// The page was looked at afterwards and shows this many new images.
        case attached(Int)
        /// Paste was sent and the page couldn't be looked at.
        case pasted
    }

    // What the page is asked. X's box and its row of attachments are found by
    // the names X gives them; if X renames them the paste still goes ahead,
    // unchecked. Single quotes only: these sit inside AppleScript strings.
    private static let box = "document.querySelector('[data-testid=tweetTextarea_0]')"
    private static let count =
        "document.querySelectorAll('[data-testid=attachments] img,[data-testid=attachments] video').length"

    /// Finds the tab showing `address`, waits for it to load and for the post
    /// box to appear, and reports "window, tab, js or nojs, box, count"
    /// separated by tabs, or nothing if no such tab turned up.
    public static func locateScript(bundleID: String, address: String) -> String {
        """
        set sep to character id 9
        set wid to 0
        set tid to 0
        with timeout of 60 seconds
          tell application id "\(quoted(bundleID))"
            set t to missing value
            repeat with i from 1 to 60
              repeat with w in windows
                try
                  set t to (first tab of w whose URL is "\(quoted(address))")
                  set wid to id of w
                  exit repeat
                end try
              end repeat
              -- X may have rewritten the address. After a few seconds, the
              -- tab in front counts if it is X's compose page.
              if t is missing value and i > 12 then
                try
                  set c to active tab of front window
                  set u to URL of c
                  if u starts with "https://x.com/intent/" or u starts with "https://x.com/compose/post" or u starts with "https://twitter.com/intent/" then
                    set t to c
                    set wid to id of front window
                  end if
                end try
              end if
              if t is not missing value then exit repeat
              delay 0.25
            end repeat
            if t is missing value then return ""
            set tid to id of t
            repeat 80 times
              if (loading of t) is false then exit repeat
              delay 0.25
            end repeat
            set how to "js"
            set seen to "0 0"
            try
              repeat 40 times
                set seen to execute t javascript "(\(box) ? '1' : '0') + ' ' + \(count)"
                if seen starts with "1" then exit repeat
                delay 0.25
              end repeat
            on error
              -- Not allowed to look. Give the page a moment to put the caret
              -- in the box, which it does by itself once it has loaded.
              set how to "nojs"
              delay 1.5
            end try
            return (wid as text) & sep & (tid as text) & sep & how & sep & (word 1 of seen) & sep & (word 2 of seen)
          end tell
        end timeout
        """
    }

    public static func parseLocate(_ output: String) -> Target? {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
        guard fields.count == 5, let window = Int(fields[0]), let tab = Int(fields[1]),
              fields[2] == "js" || fields[2] == "nojs", let already = Int(fields[4])
        else { return nil }
        return Target(window: window, tab: tab, canLook: fields[2] == "js", boxFound: fields[3] == "1", alreadyAttached: already)
    }

    /// Puts the caret in the post box, pastes, and where the page can be
    /// looked at, waits for `expecting` more images to show and reports how
    /// many are there. Reports "pasted" where it can't look.
    public static func pasteScript(bundleID: String, target: Target, expecting: Int) -> String {
        let tab = "(first tab of (first window whose id is \(target.window)) whose id is \(target.tab))"
        guard target.canLook else {
            return """
                with timeout of 20 seconds
                  tell application id "\(quoted(bundleID))"
                    paste selection \(tab)
                  end tell
                end timeout
                return "pasted"
                """
        }
        let wanted = target.alreadyAttached + expecting
        return """
            with timeout of 40 seconds
              tell application id "\(quoted(bundleID))"
                set t to \(tab)
                execute t javascript "(function () { var e = \(box); if (e && document.activeElement !== e) e.focus(); return 'ok' })()"
                delay 0.2
                paste selection t
                set seen to "\(target.alreadyAttached)"
                repeat 40 times
                  delay 0.25
                  set seen to execute t javascript "String(\(count))"
                  if (seen as integer) >= \(wanted) then exit repeat
                end repeat
                return seen
              end tell
            end timeout
            """
    }

    public static func parsePaste(_ output: String, target: Target) -> Outcome {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.canLook, target.boxFound, let seen = Int(text) else { return .pasted }
        return .attached(max(0, seen - target.alreadyAttached))
    }

    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
