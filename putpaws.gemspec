lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "putpaws/version"

Gem::Specification.new do |s|
  s.name         = "putpaws"
  s.version      = Putpaws::VERSION
  s.summary      = "Put your paws up!!"
  s.description  = "aws fargate based infra management"
  s.authors      = ["metheglin"]
  s.email        = "pigmybank@gmail.com"
  s.files        = Dir["{lib}/**/*.rb", "{lib}/**/*.rake", "bin/*", "LICENSE", "*.md", "lib/Putpawsfile"]
  s.homepage     = "https://rubygems.org/gems/putpaws"
  s.executables  = %w(putpaws)
  s.require_path = 'lib'
  s.license      = "MIT"

  s.required_ruby_version = ">= 2.7"
  s.add_dependency "rake", "~> 13.0"
  s.add_dependency "tty-prompt"
  s.add_dependency "aws-sdk-ssm"
  s.add_dependency "aws-sdk-ecs"
  s.add_dependency "aws-sdk-cloudwatchlogs"
  s.add_dependency "aws-sdk-scheduler"
end