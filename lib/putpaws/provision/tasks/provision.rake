require "fileutils"
require "putpaws/prompt"
require "putpaws/provision/all"

namespace :provision do
  desc "Interview basic infra inputs and generate provision.json + IAM policy drafts. (alias: ready)"
  task :init do
    prompt = Putpaws::Prompt.safe
    util = Putpaws::Provision::Util

    service_name = ENV['service'] || prompt.ask("Application name (Ex: awesome-api-staging):") do |q|
      q.required(true)
      q.validate(/\A[a-z0-9][a-z0-9\-]*\z/, "lowercase letters, numbers and hyphens only")
    end

    dir = Putpaws::Provision::ProvisionConfig.dir_for(service_name)
    if dir.join('provision.json').exist?
      unless prompt.yes?("#{dir}/provision.json already exists. Overwrite?", default: false)
        puts "Aborted."
        next
      end
    end

    region = prompt.ask("Region:", default: 'ap-northeast-1')
    preset_choices = Putpaws::Provision::Preset.catalog.map{|e| ["#{e[:name]} (#{e[:source]})", e[:name]]}.to_h
    preset_name = prompt.select("Preset:", preset_choices)

    puts "--- Basic infra (existing resources; used to generate IAM policies) ---"
    vpc_id = prompt.ask("VPC ID:"){|q| q.required(true)}
    subnets = prompt.ask("Subnet IDs (comma separated):"){|q| q.required(true)}.split(',').map(&:strip)
    sg_ids = prompt.ask("Security group IDs (existing, comma separated, empty to create a new one):")
      .to_s.split(',').map(&:strip).reject(&:empty?)
    ecr_arn = prompt.ask("ECR repository ARN:"){|q| q.required(true)}
    ses_arn = prompt.ask("SES identity ARN (empty to skip):")
    s3_arn = prompt.ask("S3 bucket ARN (empty to skip):")
    ssm_prefix = prompt.ask("SSM parameter path prefix (existing; putpaws never writes values):", default: "/#{service_name}")
    repo = prompt.ask("CodeBuild source repository URL (GitHub, empty to fill later):")

    data = {
      service_name: service_name,
      region: region,
      preset: preset_name,
      base: {
        vpc_id: vpc_id,
        subnets: subnets,
        security_group_ids: sg_ids,
        ecr_repository_arn: ecr_arn,
        ses_identity_arn: util.blank?(ses_arn) ? nil : ses_arn,
        s3_bucket_arn: util.blank?(s3_arn) ? nil : s3_arn,
        ssm_parameter_prefix: ssm_prefix,
      },
      roles: {
        task_execution_role_arn: nil,
        task_role_arn: nil,
        codebuild_role_arn: nil,
        scheduler_role_arn: nil,
      },
      overrides: {
        cluster_name: nil,
        cpu: nil,
        memory: nil,
        desired_count: nil,
        env: {},
        secrets: {},
      },
      devops: {
        source_repository: util.blank?(repo) ? nil : repo,
        buildspec: "buildspec.yml",
      },
    }

    Putpaws::Provision::Preset.install(preset_name)
    FileUtils.mkdir_p(dir)
    util.write_json(dir.join('provision.json'), data)

    config = Putpaws::Provision::ProvisionConfig.new(data)
    files = Putpaws::Provision::PolicyGenerator.new(config).write_step1_drafts!

    puts ""
    puts "Generated:"
    puts "  #{dir}/provision.json"
    files.each{|f| puts "  #{f}"}
    puts ""
    puts "Next steps:"
    puts "  1. Review and edit the role drafts in policies/."
    puts "     When confirmed, run `putpaws steady` to create the IAM roles from the drafts as-is."
    puts "     (or fill in existing role ARNs in provision.json instead)"
    puts "  2. Register SSM parameters (Ex: #{ssm_prefix}/RAILS_MASTER_KEY) yourself."
    puts "  3. Check with `putpaws ahead`, then build with `putpaws up`."
  end

  desc "Create IAM roles from the reviewed drafts and fill their ARNs into provision.json. Each role is shown and confirmed one by one. Idempotent. (alias: steady)"
  task :roles do
    config = Putpaws::Provision.resolve_config
    prompt = Putpaws::Prompt.safe
    puts "Service: #{config.service_name} / Account: #{config.account_id} / Region: #{config.region}"
    Putpaws::Provision::Runner.new(config: config, prompt: prompt).steady!
  end

  desc "Show what `putpaws up` would do (dry-run). (alias: ahead)"
  task :plan do
    config = Putpaws::Provision.resolve_config
    Putpaws::Provision::Runner.new(config: config, prompt: Putpaws::Prompt.safe).plan
  end

  desc "Build infra as far as possible, stopping where manual steps are required. Re-runnable. (alias: up)"
  task :up do
    config = Putpaws::Provision.resolve_config
    prompt = Putpaws::Prompt.safe
    puts "Service: #{config.service_name} / Account: #{config.account_id} / Region: #{config.region}"
    unless prompt.yes?("Proceed?")
      puts "Aborted."
      next
    end
    Putpaws::Provision::Runner.new(config: config, prompt: prompt).up!
  end
end

desc "Alias of provision:init"
task ready: 'provision:init'

desc "Alias of provision:roles"
task steady: 'provision:roles'

desc "Alias of provision:up"
task up: 'provision:up'

desc "Alias of provision:plan"
task ahead: 'provision:plan'
