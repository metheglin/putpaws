require "putpaws/ai/guide"

namespace :ai do
  desc "Install the AI agent guide (.claude/skills/putpaws/SKILL.md + a pointer in CLAUDE.md/AGENTS.md). Re-runnable. (alias: away)"
  task :install do
    files = Putpaws::Ai::Guide.install!
    puts "Generated:"
    files.each{|f| puts "  #{f}"}
    puts "Re-run `bundle exec putpaws away` after updating putpaws to refresh the guide."
  end
end

desc "Alias of ai:install"
task away: 'ai:install'
