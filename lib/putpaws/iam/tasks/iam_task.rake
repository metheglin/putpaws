require "json"
require "fileutils"
require "putpaws/prompt"
require "putpaws/iam/operator_config"
require "putpaws/iam/grant_command"

namespace :iam do
  desc "Resolve operator managed policies for this service from .putpaws/operators.json profiles. Idempotent. (Ex) profile=developer all=true"
  task :grant do
    app = fetch(:app)

    unless Putpaws::Iam::OperatorConfig.exist?
      path = Putpaws::Iam::OperatorConfig.scaffold!
      puts "Generated #{path} with example profiles."
      puts "Review and edit it, then run `putpaws #{app.name} iam:grant` again."
      next
    end

    profiles = Putpaws::Iam::OperatorConfig.all
    raise "No profiles defined in #{Putpaws::Iam::OperatorConfig.path}" if profiles.empty?

    selected = if ENV['all']
      profiles
    elsif ENV['profile']
      p = Putpaws::Iam::OperatorConfig.find(ENV['profile'])
      raise "Profile not found: #{ENV['profile']} (available: #{profiles.map(&:name).join(', ')})" unless p
      [p]
    elsif profiles.one?
      profiles
    else
      prompt = Putpaws::Prompt.safe
      name = prompt.select("Choose a profile to grant", profiles.map(&:name))
      [profiles.detect{|x| x.name == name}]
    end

    prompt = Putpaws::Prompt.safe
    cmd = Putpaws::Iam::GrantCommand.new(app: app)
    puts "Service: #{app.name} / Account: #{cmd.account_id} / Region: #{app.region}"

    selected.each do |profile|
      policy_name = cmd.policy_name(profile)
      action = cmd.plan(profile)
      if action == :skip
        puts "SKIP     #{policy_name}"
        next
      end

      doc = cmd.build_policy_document(profile)
      puts ""
      puts "=== #{action.to_s.upcase} managed policy: #{policy_name} ==="
      puts JSON.pretty_generate(doc)
      unless prompt.yes?("Apply this content as policy #{policy_name}?")
        puts "Skipped #{policy_name}"
        next
      end

      arn = cmd.apply!(profile)
      copy_dir = File.join('.putpaws', 'provisioning', app.name, 'policies')
      FileUtils.mkdir_p(copy_dir)
      File.write(File.join(copy_dir, "operator-#{profile.name}.json"), JSON.pretty_generate(doc) + "\n")
      puts "Applied: #{arn}"
      puts "Attach example: aws iam attach-user-policy --user-name <USER> --policy-arn #{arn}"
    end
  end
end
