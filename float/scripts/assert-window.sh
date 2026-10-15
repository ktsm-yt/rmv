#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" == "--help" || -z "${1:-}" ]]; then
  print "usage: $0 <running-rmv-float-pid>"
  exit 0
fi

xcrun swift - "$1" <<'SWIFT'
import Cocoa

let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let matching = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
precondition(!matching.isEmpty, "No on-screen windows found for PID \(pid).")
print("On-screen windows for PID \(pid): \(matching.count)")
SWIFT
