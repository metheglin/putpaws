require 'putpaws/provision/util'
require 'putpaws/provision/resources/base'

module Putpaws
  module Provision
    module Resources
      class CodebuildProject < Base
        # Derived from cpu_architecture; devops.environment_type / environment_image
        # override the derivation (useful for staged arch migration).
        ENVIRONMENT_TYPES = {
          'ARM64' => 'ARM_CONTAINER',
          'X86_64' => 'LINUX_CONTAINER',
        }
        DEFAULT_IMAGES = {
          'ARM64' => 'aws/codebuild/amazonlinux-aarch64-standard:3.0',
          'X86_64' => 'aws/codebuild/standard:7.0',
        }

        def name
          config.build_project_name
        end

        def devops
          config.devops_settings
        end

        def environment_type
          devops[:environment_type] || ENVIRONMENT_TYPES.fetch(config.cpu_architecture)
        end

        def environment_image
          devops[:environment_image] ||
            (devops[:environment_images] || {})[config.cpu_architecture.to_sym] ||
            DEFAULT_IMAGES.fetch(config.cpu_architecture)
        end

        def security_group_ids
          ids = state.resources[:security_group_ids]
          raise "security_group_ids not found in state. Run the service step first." if ids.nil? || ids.empty?
          ids
        end

        def desired_params
          {
            name: name,
            description: "Managed by putpaws for #{config.service_name}",
            source: {
              type: devops[:source_type] || 'GITHUB',
              location: devops[:source_repository],
              buildspec: devops[:buildspec] || 'buildspec.yml',
            },
            artifacts: {type: 'NO_ARTIFACTS'},
            environment: {
              type: environment_type,
              image: environment_image,
              compute_type: devops[:compute_type] || 'BUILD_GENERAL1_SMALL',
              privileged_mode: devops.fetch(:privileged_mode, true),
            },
            service_role: config.roles[:codebuild_role_arn],
            logs_config: {
              cloud_watch_logs: {status: 'ENABLED', group_name: config.build_log_group}
            },
            # CI needs VPC access (Ex: db:migrate against RDS). Reuse the
            # service security group so the build reaches whatever the app can.
            vpc_config: {
              vpc_id: config.base[:vpc_id],
              subnets: config.base[:subnets],
              security_group_ids: security_group_ids,
            },
            tags: [MANAGED_TAG],
          }
        end

        def current
          res = clients.codebuild.batch_get_projects(names: [name])
          res.projects.first
        end

        def changed?(current)
          current.source&.type != desired_params[:source][:type] ||
            current.source&.location != desired_params[:source][:location] ||
            current.source&.buildspec != desired_params[:source][:buildspec] ||
            current.service_role != desired_params[:service_role] ||
            current.environment&.type != desired_params[:environment][:type] ||
            current.environment&.image != desired_params[:environment][:image] ||
            current.environment&.compute_type != desired_params[:environment][:compute_type] ||
            current.vpc_config&.subnets.to_a.sort != desired_params[:vpc_config][:subnets].sort ||
            current.vpc_config&.security_group_ids.to_a.sort != desired_params[:vpc_config][:security_group_ids].sort
        end

        def create!
          res = clients.codebuild.create_project(**desired_params)
          {codebuild_project: res.project.name}
        end

        def update!(_current)
          res = clients.codebuild.update_project(**desired_params)
          {codebuild_project: res.project.name}
        end

        def outputs(current)
          {codebuild_project: current.name}
        end
      end
    end
  end
end
