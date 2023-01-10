require "putpaws/dsl"
include Putpaws::DSL

apps = Putpaws::ApplicationConfig.all

apps.each do |app|
  Rake::Task.define_task(app.name) do
    set(:app, app)
  end
end