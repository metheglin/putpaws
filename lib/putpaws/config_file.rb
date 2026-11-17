require 'json'
require 'pathname'
require 'fileutils'

module Putpaws
  class Error < StandardError; end
  class ConfigError < Error; end
  class LegacyConfigError < ConfigError; end

  # Reads and writes the JSON files under .putpaws/.
  #
  #   .putpaws/
  #   ├── infra.json                 parts (network / target), shared by all environments
  #   ├── <environment>/
  #   │   ├── application.json       environment settings (operate what is running)
  #   │   ├── launch.json            named launches (start tasks)
  #   │   └── schedule.json          schedules (a launch + when to run)
  #   └── provisioning/              provisioning inputs and state
  module ConfigFile
    DEFAULT_ROOT = '.putpaws'
    # Files of the 0.1.x layout, which lived right under .putpaws/.
    LEGACY_FILES = %w[application.json schedule.json]

    def self.root
      @root || DEFAULT_ROOT
    end

    def self.root=(path)
      @root = path
    end

    def self.read(path)
      path = Pathname.new(path)
      return {} unless path.exist?
      data = JSON.parse(File.read(path, encoding: 'UTF-8'), symbolize_names: true)
      raise ConfigError, "#{path} must be a JSON object" unless data.is_a?(Hash)
      data
    rescue JSON::ParserError => e
      raise ConfigError, "#{path} is not valid JSON: #{e.message}"
    end

    def self.write(path, data)
      FileUtils.mkdir_p(File.dirname(path.to_s))
      File.write(path.to_s, JSON.pretty_generate(data) + "\n", encoding: 'UTF-8')
    end

    def self.legacy_files(path_prefix: root)
      LEGACY_FILES.map{|f| Pathname.new(path_prefix).join(f)}.select(&:file?)
    end

    # Top-level keys of the legacy application.json: the names people used to
    # pass as the first argument. Only used to answer them with a migration hint.
    def self.legacy_application_names(path_prefix: root)
      file = Pathname.new(path_prefix).join('application.json')
      return [] unless file.file?
      data = JSON.parse(File.read(file, encoding: 'UTF-8')) rescue nil
      data.is_a?(Hash) ? data.keys.map(&:to_s) : []
    end

    def self.legacy_message(files)
      "Legacy config found: #{files.map(&:to_s).join(', ')}\n" +
        "putpaws 1.0 reads settings per environment folder " +
        "(.putpaws/<environment>/application.json, launch.json, schedule.json) and no longer reads these files.\n" +
        "Move the settings into the environment folder (`putpaws up` generates application.json and launch.json), " +
        "then delete the legacy files."
    end

    def self.ensure_no_legacy!(path_prefix: root)
      files = legacy_files(path_prefix: path_prefix)
      raise LegacyConfigError, legacy_message(files) unless files.empty?
    end
  end
end
