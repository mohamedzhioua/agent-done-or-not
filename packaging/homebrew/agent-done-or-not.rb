# Homebrew formula for agent-done-or-not.
#
# This file is the canonical source for the formula. To distribute it, copy it
# into a tap repo (e.g. mohamedzhioua/homebrew-tap as Formula/agent-done-or-not.rb)
# and push — users then run:
#
#   brew install mohamedzhioua/tap/agent-done-or-not
#
# The bash engine is canonical; this formula is a thin wrapper that installs the
# gate scripts to libexec and puts an `agent-done-or-not` launcher on PATH.
class AgentDoneOrNot < Formula
  desc "Proof-of-done gate that makes AI agents prove a task is done before claiming it"
  homepage "https://github.com/mohamedzhioua/agent-done-or-not"
  url "https://github.com/mohamedzhioua/agent-done-or-not/archive/refs/tags/v0.12.0.tar.gz"
  sha256 "da39d79e77c01843dae95bef69437c866d9dd30a92438d6151c79c55b80d0ea3"
  license "MIT"

  depends_on "bash"

  def install
    libexec.install "done-gate.sh", "stop-gate.sh", "subagent-audit.sh",
                    "proof.schema.json", "claim.schema.json", "policy.schema.json"

    bash = Formula["bash"].opt_bin/"bash"

    (bin/"agent-done-or-not").write <<~SH
      #!/bin/bash
      exec "#{bash}" "#{libexec}/done-gate.sh" "$@"
    SH

    (bin/"agent-done-stop-gate").write <<~SH
      #!/bin/bash
      exec "#{bash}" "#{libexec}/stop-gate.sh" "$@"
    SH

    (bin/"agent-done-subagent-audit").write <<~SH
      #!/bin/bash
      exec "#{bash}" "#{libexec}/subagent-audit.sh" "$@"
    SH
  end

  def caveats
    <<~EOS
      The proof engine is installed. To enforce proof-of-done in Claude Code,
      wire the Stop hook in your .claude/settings.json to:

        #{opt_bin}/agent-done-stop-gate

      To audit a subagent's claims before the parent trusts them, wire the
      SubagentStop hook to:

        #{opt_bin}/agent-done-subagent-audit

      See: #{homepage}/blob/main/examples/install.md
    EOS
  end

  test do
    # capture a passing check, then assert it — proves the wrapper resolves the
    # bundled engine and writes a receipt into the working directory.
    system bin/"agent-done-or-not", "capture", "--label", "brew-test", "--", "true"
    assert_predicate testpath/".agent-proof", :directory?
    system bin/"agent-done-or-not", "assert", "--label", "brew-test"

    # a failing command must propagate a non-zero exit (green cannot be faked).
    # shell_output asserts the command exits with the given status (1 here).
    shell_output("#{bin}/agent-done-or-not capture --label brew-fail -- false", 1)
  end
end
