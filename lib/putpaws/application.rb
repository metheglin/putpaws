module Putpaws
  class Application < Rake::Application
    def initialize
      super
      @rakefiles = %w{putpawsfile Putpawsfile putpawsfile.rb Putpawsfile.rb}
    end

    def name
      "putpaws"
    end

    def run(argv = ARGV)
      Rake.application = self
      super
    end

    # Mistakes in settings or parameters (Putpaws::Error) are answered with
    # the message alone; a backtrace would only bury it. --trace shows it.
    def display_error_message(ex)
      if ex.is_a?(Putpaws::Error) && !options.trace
        trace "#{name} aborted!"
        trace ex.message
      else
        super
      end
    end

    def find_rakefile_location
      putpawsfile = File.expand_path(File.join(File.dirname(__FILE__), "..", "Putpawsfile"))
      if (location = super).nil?
        [putpawsfile, Dir.pwd]
      else
        location
      end
    end
  end
end
