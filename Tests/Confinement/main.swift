// The other half of the tenancy fence: the directory.
//
// The classifier is a judgement and this is not — an off-tenant delegate is
// given an empty folder of its own and `Isolation` refuses everything outside
// it, whatever anyone concluded about the task. Touches the real Application
// Support folder, because the thing under test is where the folder is put.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

Support.prepare()
let run = UUID()
guard let scratch = Tenancy.scratch(for: .kimi, run: run) else {
    print("  FAIL scratch directory not created"); exit(1)
}
check("scratch exists", FileManager.default.fileExists(atPath: scratch.path))
let contents = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? ["?"]
check("scratch is empty", contents.isEmpty)
let mode = (try? FileManager.default.attributesOfItem(atPath: scratch.path)[.posixPermissions]) as? NSNumber
check("scratch is 0700", mode?.intValue == 0o700)
check("scratch is under Honeycode support, not the project",
      scratch.path.hasPrefix(Support.folder.path))

// The file fence: from that root, the project is unreachable.
let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
check("project file is not permitted from the scratch root",
      !Isolation.permits(project.appendingPathComponent("Sources/AgentKit/Crew.swift").path,
                         root: scratch))
check("the user's home is not permitted",
      !Isolation.permits(NSHomeDirectory() + "/.ssh/id_ed25519", root: scratch))
check("its own directory is permitted",
      Isolation.permits(scratch.appendingPathComponent("notes.md").path, root: scratch))

// Two runs never share a folder.
let other = Tenancy.scratch(for: .kimi, run: UUID())
check("a second run gets a different folder", other?.path != scratch.path)
// Two agents in one run never share one either.
let sibling = Tenancy.scratch(for: .copilot, run: run)
check("two delegates in one run get different folders", sibling?.path != scratch.path)

try? FileManager.default.removeItem(at: Support.folder.appendingPathComponent("Crew"))
print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
