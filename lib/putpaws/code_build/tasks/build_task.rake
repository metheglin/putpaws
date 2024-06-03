require "putpaws/prompt"
require "putpaws/code_build/project_command"

namespace :code_build do
  desc "Set CodeBuild project."
  task :set_project do
    aws = Putpaws::CodeBuild::ProjectCommand.config(fetch(:app))
    codebuild_projects = aws.list_codebuild_projects.map{|x| 
      [x.name, x]
    }.to_h
    prompt = Putpaws::Prompt.safe
    selected = prompt.select("Choose a project you're going to operate", codebuild_projects.keys)
    codebuild_project = codebuild_projects[selected]

    set :codebuild_project, codebuild_project
  end

  desc "Start build."
  task build: :set_project do
    aws = Putpaws::CodeBuild::ProjectCommand.config(fetch(:app))

    source_version = if ENV['branch']
      aws.build_source_version(type: :branch, version: ENV['branch'])
    elsif ENV['tag']
      aws.build_source_version(type: :tag, version: ENV['tag'])
    elsif ENV['commit_id']
      aws.build_source_version(type: :commit_id, version: ENV['commit_id'])
    else
      raise "Please specify required parameter like: branch=main or tag=release/20240601 or commit_id=0f0f0f0f"
    end
    codebuild_project = fetch(:codebuild_project)
    aws.codebuild_project = codebuild_project
    aws.start_build_with_specific_version(
      source_version: source_version, 
      environment_variables: ENV['env'] ? JSON.parse(ENV['env']) : {}, 
      buildspec_override: ENV['buildspec']
    )
  end
end
