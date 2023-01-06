require "putpaws/dsl"
include Putpaws::DSL

apps = Putpaws::ApplicationConfig.all

apps.each do |app_name, app|
  Rake::Task.define_task(app_name) do
    set(:app, app)
  end
end