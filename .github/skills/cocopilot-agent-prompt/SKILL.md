---
name: cocopilot-agent-prompt
description: Produces the restart command or the paste-ready (re)start prompt for a cocopilot peer agent (agent-a or agent-b) paired on a target repository. Use when the user asks to restart, relaunch, or reconnect a cocopilot agent-a/agent-b window, asks for the prompt or command for such a window, or when a cocopilot agent window has crashed or closed.
metadata:
  version: "0.0.1"
  spec: "https://agentskills.io/specification"
allowed-tools: shell
---

cocopilot pairs two GitHub Copilot CLI sessions (agent-a and agent-b) on a target repository.
The agents coordinate through a mailbox in a pair directory outside the target.
A pair uses one of two transports.
In a `mailbox` pair each agent waits with a background watch.
In a `direct` pair the agents wake each other with native peer messages, and `<pair dir>\sessions.json` registers both sessions.
Run every command below in pwsh.

1. **Find the cocopilot install (`<install>`).**
   - When you can see this skill's own path, take its directory (for a `SKILL.md` file path, use the folder that holds it).
     `<install>` is three levels above that folder: `<install>\.github\skills\cocopilot-agent-prompt`.
   - Otherwise run `copilot config skillDirectories`.
     For each entry, the candidate is the entry's parent's parent, when that folder contains `scripts\start-agents.ps1`.
     Use a candidate only when there is exactly one. Otherwise ask the user which install to use.
   - Check that `<install>\scripts\start-agents.ps1` and `<install>\scripts\_state.ps1` exist.
     If they do not, ask the user for the install directory.
   - Never use a hard-coded path, the first of several matches, or a profile function such as `cocopilot-prompt`.
     Agent shells run `pwsh -NoProfile`, so profile functions do not exist there.
2. **Find the target repository (`<target>`)**: the repository being paired on, which is not necessarily the cocopilot install.
   Default to the current working directory when it looks like a real project.
   Ask the user when it is ambiguous.
3. **Find the role**: `a` or `b`. Ask the user when it is ambiguous.
4. **Open the mailbox** and keep the returned path as `<pair dir>`:

   ```powershell
   & { . "<install>\scripts\_common.ps1"; Open-CocopilotMailbox -RepoPath "<target>" }
   ```

   - If it refuses because of a legacy in-repo mailbox (`<target>\.mailbox`), tell the user to stop both agents and run
     `& "<install>\scripts\init-mailbox.ps1" -RepoPath "<target>" -MigrateLegacy -AgentsStopped`,
     or to discard the old mailbox with `<install>\scripts\cleanup-mailbox.ps1`. Then stop.
   - If there is no mailbox yet, run `& "<install>\scripts\init-mailbox.ps1" -RepoPath "<target>"`
     (add `-AllowNonGit` when the target is not a git repository), then open the mailbox again.
   - For any other refusal, report its message and stop.
   - Never add `-AcknowledgeHistory`. Only the user may count unread mailbox history as handled.

5. **Direct pair** (`<pair dir>\sessions.json` exists): a new window gets a new session id, so its peer could never wake it.
   Give a restart command instead of a prompt.
   - Validate the registration with the cocopilot helpers and take the session id from that same result.
     `<role>` is the role to restart (`agent-a` or `agent-b`), `<peer>` is the other role:

     ```powershell
     & { . "<install>\scripts\_common.ps1"
         Get-CocopilotPeerNotification -MailboxDir "<pair dir>" -RepoPath "<target>" -Role "<peer>" -ConfigDir (Get-CocopilotConfigDir) |
             Select-Object State, Reason, PeerSessionId }
     ```

     Called for `<peer>`, `Get-CocopilotPeerNotification` reads `sessions.json` once with `Read-CocopilotSessionRegistration`
     and returns the registration of `<role>` as `PeerSessionId`.
     State `Ready` means the record is valid, belongs to this target (`Test-CocopilotSameTarget`)
     and to this Copilot configuration directory (`Get-CocopilotConfigDir`), and `PeerSessionId` is a GUID.
     If the state is not `Ready`, stop and report the reason.
     Use only this `PeerSessionId`. Do not read `sessions.json` again.

   - Give the command with that GUID:

     ```powershell
     copilot --resume <PeerSessionId> --add-dir "<pair dir>" --add-dir "<install>" --max-autopilot-continues 0 <flags>
     ```

     `<flags>` are the same model, mode and permission flags the window was started with.
     When you do not know them, ask the user.
     You may offer the launcher's defaults as an explicitly labelled option: `--model <model of their choice> --autopilot --allow-all`.
     Never add flags silently.

   - Explain that the resumed session keeps its id, its registration and its conversation, so it needs no pasted prompt.
     It drains the mailbox on its next turn or peer message.
   - If the session cannot be resumed, the whole pair must be relaunched on the same transport.
     Tell the user to stop the old agent windows first, then run:

     ```powershell
     & "<install>\scripts\start-agents.ps1" -RepoPath "<target>" -Transport direct
     ```

     Keep `-Transport direct`. Change the transport only when the user explicitly asks for it.

6. **Mailbox pair** (no `sessions.json`): render the exact prompt with the script. Never paraphrase or hand-write it.
   The other agent reads it literally, and the script resolves paths and the current mailbox state.

   ```powershell
   & "<install>\scripts\render-prompt.ps1" -Agent <a|b> -RepoPath "<target>"
   ```

   - If it refuses, report its message. Never pass `-Transport` to get around it: both agents of a pair must use the same transport.
   - Write the output to a file in the session files folder (or `%TEMP%` when that folder is unknown).
     Also copy it to the clipboard with `Set-Clipboard` when that works.
   - In chat give only the file path, a one-line summary, and the flags the new window needs:
     `--add-dir "<pair dir>" --add-dir "<install>"`.

7. **After a crash**, reassure the user only about what the mailbox holds.
   Committed mailbox state and history live in `<pair dir>`, not in the crashed conversation.
   Entries the agent had not acknowledged are delivered again by its read or watch command.
   A write that the crash interrupted may show up with the `INCOMPLETE` label; ask the user to inspect that entry before relying on it.
8. Do not run `start-agents.ps1` unless the user asks to launch new windows.
