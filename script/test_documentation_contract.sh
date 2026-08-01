#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

/usr/bin/grep -Fq 'Unattended hard restart is **not enabled' "$ROOT_DIR/README.md"
/usr/bin/grep -Fq '`recover_agent`' "$ROOT_DIR/TECHNICAL_SETUP.md"
/usr/bin/grep -Fq 'Automatic restart unavailable' "$ROOT_DIR/docs/RECOVERY_WORKFLOWS.md"
/usr/bin/grep -Fq 'listener is disabled by default' "$ROOT_DIR/SECURITY.md"
/usr/bin/grep -Fq 'experimental client' "$ROOT_DIR/README.md"
/usr/bin/grep -Fq 'not a shipped remote controller' "$ROOT_DIR/Phone/README.md"

DOC_FILES="$(/usr/bin/git -C "$ROOT_DIR" ls-files --cached --others --exclude-standard '*.md')"
DOC_FILES="$DOC_FILES" /usr/bin/ruby - "$ROOT_DIR" <<'RUBY'
root = ARGV.fetch(0)
files = ENV.fetch("DOC_FILES").lines.map(&:strip).reject(&:empty?)
  .map { |path| File.join(root, path) }
broken = []
files.each do |file|
  text = File.read(file)
  text.scan(/\[[^\]]*\]\(([^)]+)\)/).flatten.each do |target|
    next if target.start_with?("http://", "https://", "mailto:", "#")
    path = target.split("#", 2).first
    next if path.empty?
    resolved = File.expand_path(path, File.dirname(file))
    broken << "#{file.delete_prefix(root + "/")}: #{target}" unless File.exist?(resolved)
  end
end
unless broken.empty?
  warn "Broken local documentation links:"
  broken.sort.each { |entry| warn entry }
  exit 1
end
RUBY

/bin/echo 'Documentation contract test passed'
