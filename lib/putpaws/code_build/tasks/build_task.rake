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

  desc "Start build. Pass wait=true to wait until the build completes and fail on error. (Ex) branch=main wait=true"
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
    res = aws.start_build_with_specific_version(
      source_version: source_version,
      environment_variables: ENV['env'] ? JSON.parse(ENV['env']) : {},
      buildspec_override: ENV['buildspec']
    )
    build = res.build
    puts "Build started: #{build.id}"

    if ENV['wait']
      puts "Waiting for the build to complete..."
      build = aws.wait_until_build_complete(build.id)
      if build.build_status == 'SUCCEEDED'
        puts "Build succeeded: #{build.id}"
      else
        raise "Build #{build.build_status.downcase}: #{build.id}"
      end
    end
  end
end
