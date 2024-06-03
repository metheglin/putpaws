require 'aws-sdk-codebuild'
# require 'aws-sdk-ssm'

module Putpaws::CodeBuild
  class ProjectCommand
    def self.config(config)
      new(**config.codebuild_command_params)
    end

    attr_reader :codebuild_client
    attr_reader :region, :project_name_prefix
    attr_accessor :codebuild_project
    def initialize(region:, project_name_prefix: nil)
      @codebuild_client = Aws::CodeBuild::Client.new({region: region})
      @region = region
      @project_name_prefix = project_name_prefix
      @codebuild_project = nil
    end

    def list_codebuild_projects
      res = codebuild_client.batch_get_projects(names: [project_name_prefix])
      res.projects.select{|pr| pr.name.start_with?(project_name_prefix)}
    end

    def start_build_with_specific_version(source_version:, environment_variables: {}, buildspec_override: nil, artifacts_override: nil)
      current_variables = codebuild_project.environment.environment_variables.map{|x| [x.name, {type: x.type, value: x.value}]}.to_h
      new_variables = environment_variables.reduce(current_variables) {|acc,(k,v)| acc[k] = {type: 'PLANTTEXT', value: v}}
      environment_variables_override = new_variables.map{|k,v| v.merge(name: k)}
      params = {
        project_name: codebuild_project.name,
        source_version: source_version,
        environment_variables_override: environment_variables_override,
      }
      if buildspec_override
        params = params.merge(buildspec_override: buildspec_override)
      end
      if artifacts_override
        params = params.merge(artifacts_override: artifacts_override)
      end

      codebuild_client.start_build(**params)
    end

    def build_source_version(type:, version:)
      type = type.to_sym
      if type == :branch
        "refs/heads/#{version}"
      elsif type == :tag
        "refs/tags/#{version}"
      elsif type == :commit_id
        version
      else
        raise "Please specify valid type: branch or tag or commit_id"
      end
    end
  end
end
