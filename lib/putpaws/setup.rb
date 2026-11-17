require "putpaws/dsl"
include Putpaws::DSL

# The first argument of a command is always the environment:
#   putpaws <environment> <task> key=value ...
# Every environment folder (.putpaws/<environment>/application.json) becomes
# a task which selects that environment for the tasks that follow.
environments = Putpaws::ApplicationConfig.names

environments.each do |name|
  Rake::Task.define_task(name) do
    set(:app, Putpaws::ApplicationConfig.find(name))
  end
end

# Names of the 0.1.x layout (top-level keys of .putpaws/application.json)
# answer with a migration hint instead of "Don't know how to build task".
(Putpaws::ConfigFile.legacy_application_names - environments).each do |name|
  Rake::Task.define_task(name) do
    Putpaws::ConfigFile.ensure_no_legacy!
  end
end
